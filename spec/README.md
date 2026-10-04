# PhotoDuck v1 Implementation Spec

This folder is the single source of truth for turning PhotoDuck into a working iOS app that frees real storage on real iPhones, safely, and can ship on the App Store. It replaces `FIXSPEC.md`, `PERFORMANCE_MASTER_PROMPT.md` and the "Implementation status" section of `ROADMAP.md`. Those files are now historical context only; WS-58 moves them to `docs/archive/`.

It was produced on 2026-09-27/28 from:
- a 12-scope code review: 225 findings, 44 of them merged as duplicates;
- a simulator smoke test;
- a verification pass, in which each chapter's author re-checked every finding against the code before writing it up. Result: **181 confirmed, 42 partially true (the fix was adjusted), 1 checkable only on a device, and 0 refuted.** Each chapter's *Verification notes* table records what was actually true.

The plan is **64 workstreams in 13 chapters**. Each workstream is sized to be one branch and one PR. The chapters were then reconciled against each other; the resulting shared names and handoffs are listed in §9.

**If you are Claude Sonnet (or any implementer), read this whole file once, then work one workstream at a time from its chapter.**

---

## 1. Where the app stands

**Works and must be preserved**
- Destructive intent is always explicit (`keeperAssetID` plus `deleteCandidateIDs`). `PhotoGroup.init` and `PhotoDeletionGuardrails` downgrade any malformed, stale or `visuallySimilar` plan to review-only.
- There is one photo-deletion gateway (`DeletionManager`).
- Scans are bounded and cancellable. Runs are fenced by `activeScanID` and a run lock. Checkpoints are written atomically, ordered by generation, with a backup and poisoned-snapshot detection.
- The image repository coalesces requests and bounds its cache.
- StoreKit 2 handling is careful and tested.
- Export copies, verifies, and only then offers deletion.
- The build has zero warnings under strict concurrency, and 256 of 257 tests pass (1 skipped).

**Blocks shipping or usefulness today** (details in the chapters)
1. **Upload blockers**
   - `PrivacyInfo.xcprivacy` is missing the SystemBootTime and FileTimestamp required-reason APIs the code calls (ITMS-91053).
   - The target is universal (`TARGETED_DEVICE_FAMILY = "1,2"`) with a portrait-only iPad and no `UIRequiresFullScreen` (ITMS-90474).
2. **Live data-safety bugs**
   - Group-detail **Keep Best deletes photos the grid shows as "Kept"**. It commits the classifier plan and ignores the user's edited selection.
   - **Duck Mode shows the first card's image on every later card**, so users delete photos they never saw.
   - An **export resume can splice two different files**, and Export & Delete then removes the original after a size-only check.
   - The documented **10-second undo window is dead code**: `DeletionManager.scheduleDelete` has no callers. Every delete goes straight to the iOS prompt while the UI and CLAUDE.md still promise undo.
3. **The simulator cannot analyze a single photo.** `VNGenerateImageFeaturePrintRequest` fails with Vision error 9 ("Could not create inference context"). No group, Keep Best or Duck Mode flow can be exercised until the fixture analyzer from WS-07 exists.
4. **Little reclaim value in practice**
   - Identical copies never qualify for one-tap Keep Best: tied keeper scores fail the 0.08 margin rule.
   - Thresholds were never calibrated against real photos.
   - Sharpness is measured on a 64×64 image.
   - Edits are inferred from `modificationDate`.
   - Preference learning quietly switches Keep Best off.
   - Hidden burst frames are never fetched.
   - Large Videos, usually most of the bytes, only scans after a full photo Deep Clean and never refreshes.
   - Screenshots and videos can only be deleted one at a time.
5. **Numbers are not honest**
   - iCloud-only originals are counted as reclaimable iPhone space.
   - "Freed" counts bytes that only moved to Recently Deleted.
   - The completion sheet and Home contradict each other and hide total analysis failure.
6. **Scan lifecycle**
   - A photo added mid-scan poisons the completed snapshot.
   - Limited access deletes the full-library analysis.
   - Pause/resume drops the run lock.
   - Scans stop when the phone locks, and interrupted scans never resume.
   - Launch decodes the ~20 MB snapshot up to 6×.
   - Checkpoints write gigabytes over a 60k first scan.
7. **Own footprint.** About 0.6–0.7 GB of regenerable caches sit in backed-up Application Support, and Release builds run an unused ML training pipeline.
8. **HomeViewModel** is a 2,640-line object with no test seam, and about 25 workstreams must touch it.

---

## 2. Tracks: what to build first

Execute workstreams in numeric order, **but finish Track A before starting any Track B workstream.** Track A is dependency-closed, so every Track A workstream depends only on other Track A workstreams.

| Track | What you get | Workstreams |
|---|---|---|
| **A: Useful, safe, honest on a real iPhone** | Upload blockers and P0s fixed. The simulator harness and CI exist. One honest deletion API. Correct incremental scans and library consistency. Videos first. Scans survive lock and backgrounding. Honest bytes and "freed". Keep Best that fires on verified identical copies. Bulk screenshots and large videos. A coherent free/paid policy. | WS-01, WS-02, WS-03, WS-04, WS-05, WS-06, WS-07, WS-08, WS-09, WS-10, WS-11, WS-12, WS-13, WS-14, WS-15, WS-16, WS-17, WS-18, WS-19, WS-20, WS-21, WS-22, WS-23, WS-24, WS-25, WS-26, WS-27, WS-28, WS-29, WS-30, WS-31, WS-32, WS-33, WS-35, WS-36, WS-37, WS-38, WS-41, WS-42 (39) |
| **B: App Store ready and fast at 60k** | Compression safety and UX, burst extras, calibrated thresholds, byte-led Home, bounded own footprint, privacy/settings surface, performance at scale, accessibility, export resilience, release engineering. | WS-34, WS-39, WS-40, WS-43, WS-44, WS-45, WS-46, WS-47, WS-48, WS-49, WS-50, WS-51, WS-52, WS-53, WS-54, WS-55, WS-56, WS-57, WS-58 (19) |
| **C: Post-v1 growth** | Live Photo measurement and conversion, RAW/48 MP, cross-date copies, duplicate videos, sensitivity presets, retention loop. | WS-59, WS-60, WS-61, WS-62, WS-63, WS-64 (6) |

Tracks decide the **order of work**. Milestones (§7) decide **when a quality bar is met**. A milestone closes only when all of its workstreams are done, including any in Track B. For example, M2's compression exit criteria wait for WS-43 and WS-44 even though Track A finishes first.

**Cut lines** (these may slip without breaking v1):
- WS-39 (calibration)
- WS-40 (bursts)
- WS-45 (Home ordering)
- WS-49 (final HomeViewModel extraction)
- WS-52 (thumbnail prefetch). WS-54 needs WS-52's `LRUCache`, so if WS-52 is cut, WS-54 lands WS-52.1 as its first commit.
- The CTA-gradient part of WS-56.

**Never cut** (these fix live data loss, monetization or safety): WS-04, WS-05, WS-17, WS-19, WS-20, WS-36, WS-43.

> **Compression before WS-43.** Video compression ships today with known data-safety gaps: a declined delete prompt leaves duplicates, album membership is lost, and compression fails on screen lock. If a Track A build goes to anyone other than the owner, gate the compression entry point behind `#if DEBUG` until WS-43 lands. That is a one-line change; note it in the PR.

---

## 3. How to execute a workstream (operating rules)

1. **Pick the next workstream.** Choose the lowest-numbered workstream in the current track whose status is `todo` and whose dependencies are all `done` (§7). Do one workstream at a time.
2. **Start clean.**
   - Run `cd ios-cleanup && git status --short --branch`. The tree must be clean; WS-01 is the exception, because it commits the existing WIP.
   - Create `ws/NN-short-slug` from `main`. Until WS-01 lands, `main` does not yet contain the active line, so WS-01 itself tells you what to do.
3. **Read before coding.**
   - Read your workstream section in its chapter.
   - Read the *Acceptance criteria* of every dependency, so you know which seams and types already exist.
   - Read the decisions the workstream cites (§6).
4. **Re-verify the code.** The *Current behavior (verified)* bullets cite `path:line` as of 2026-09-27, and lines drift. Re-find each one. If the code has changed so the spec no longer applies (for example, it's already fixed or structured differently), adapt minimally and record it under **Deviations** in your PR summary.
5. **Implement tasks in order.** Commit once per task, with messages like `WS-NN.k: <what changed>`. Commit only on the workstream branch.
   - **Pushing, merging to `main`, rewriting history and touching the outer `/Users/justinwong/iOSCLEANER` repo all require the owner's explicit approval.** When the workstream is done, stop and report.
   - If the owner has approved an autonomous merge policy, follow it.
6. **Build and test.** Run the full suite (§4), plus every new test the spec lists. The build must stay warning-free. Never weaken or delete an existing test to make it pass; if a test encodes behavior the spec changes, update it and explain why in the PR summary.
7. **Check acceptance.**
   - Tick every acceptance criterion with evidence: a test name, command output, or a screenshot path.
   - If a criterion can only be checked on a real device, write **needs device QA** and make sure its steps are in `docs/DEVICE_QA.md` (created by WS-09).
8. **Update docs.**
   - Update `ios-cleanup/CLAUDE.md` when architecture, invariants, monetization or deletion semantics change.
   - Update this README's status table: status, the date, a one-line note, and the final commit hash.
   - Put any out-of-scope problem you notice in `spec/BACKLOG.md` (create it if needed) instead of fixing it.
9. **Report.** Finish with:
   - What changed.
   - Test evidence.
   - Deviations from the spec, with reasons.
   - Device-QA items still open.
   - Follow-ups.

**Conflict rules**
- The code is the truth about *current* behavior. The spec is the truth about *intended* behavior. The invariants in §5 override both.
- If a spec instruction would violate an invariant, do not implement it. Stop and flag it.
- If you need a genuinely new product decision, pick the safest default, mark it `DECISION (owner may override)` in code comments and in the PR summary, and add it to §6.

**Engineering rules**
- No Swift Package Manager dependencies. No third-party SDKs. No network services.
- Do no synchronous PhotoKit enumeration, JSON, SQLite, image decoding or filesystem work on the main actor.
- Put new logic in new small files. Do not grow `HomeViewModel.swift`, `PhotoScanEngine.swift`, `SharedHelpers.swift`, `FileResultsView.swift` or `HomeView.swift`; extract from them where the spec says to.
- Tests must not sleep or depend on wall-clock timing. Use injected clocks, providers and doubles.
- Nothing may be unbounded: tasks, caches, buffers, arrays and PhotoKit requests all need limits.
- Similarity thresholds change only in WS-39, with recorded evidence.
- Every change to deletion or purchase code needs a test.
- Under `Views/`, use the design tokens (`DuckTheme`, `duck*` fonts). `.font(.system(size:))` is linted by `DesignLintTests`.
- Do not visually redesign Duck Mode, Files/compression, Paywall or Onboarding beyond what a workstream specifies; they await a design handoff. Functional and accessibility fixes are expected.

---

## 4. Build, test, run

```bash
cd /Users/justinwong/iOSCLEANER/ios-cleanup

# Build
xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Full test suite. After WS-06 this runs the default plan, iOSCleanup.xctestplan
xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# Scale benchmarks (after WS-06/WS-08; nightly and on performance-labelled PRs, not on every PR)
xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -testPlan Performance test

# One test
xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:iOSCleanupTests/SimilarityPolicyTests/testDeleteCandidateIDsNeverIncludeKeeperAssetID test
```

**Running the app in the simulator**
- iPhone 17 Pro is the target simulator; iPhone 16 is not installed on this Mac.
- Install and launch with `xcrun simctl install booted <path to iOSCleanup.app>` and `xcrun simctl launch booted com.photoduck.app`.
- Stream logs with `xcrun simctl spawn booted log stream --style compact --predicate 'process == "iOSCleanup"'`.
- App diagnostics live at `Library/Application Support/PhotoDuck/Diagnostics/events-v1.jsonl` inside the app data container (`xcrun simctl get_app_container booted com.photoduck.app data`).
- `simctl privacy grant photos` did not take effect in testing. Grant access by tapping **Start scan**, then **Allow Full Access**.
- **Vision does not work in the simulator** (error 9). Until WS-07 lands, every photo ends up "unanalyzed". Afterwards, launch with the fixture-analyzer argument defined in WS-07 (chapter 02), and seed fixture photos with `xcrun simctl addmedia booted <files>`.
- iOS 26 renders `.confirmationDialog` as an anchored popover. Some screenshot tools miss it; `xcrun simctl io booted screenshot out.png` captures it.

**Real device.** PhotoKit locality, iCloud "Optimize iPhone Storage", system delete prompts, background execution, thermal behavior and Vision on real photos can only be validated on a device. WS-09 creates `docs/DEVICE_QA.md` and a baseline run, and every later workstream appends its device steps there.

---

## 5. Invariants (non-negotiable)

1. Never infer a keeper or delete candidate from array order. Destructive intent is carried only as explicit keeperAssetID and deleteCandidateIDs, and every group construction or rebuild (rehydrate, prune, reconcile, regroup, presets) goes through PhotoGroup.init, which downgrades malformed, stale, low-confidence, blocked, visuallySimilar or keeper-missing plans to reviewManually with empty deleteCandidateIDs.
2. visuallySimilar groups stay review-only at every layer (pair classifier, PreferenceAdjustedRecommendationService, makeGroups finalAction, PhotoGroup.init, PhotoDeletionGuardrails, isAutoCleanEligible, Duck Mode queue, Auto-clean). New rules (identical copies, burst extras, cross-date copies, duplicate videos, presets) pass through the same gates, never around them; presets may only change review-only thresholds.
3. The keeper is never in the delete set, a plan never deletes a whole group, and cross-group keeper/delete conflicts are rejected. Keeper protection and validateManualSelection in group detail survive every refactor.
4. All photo deletion goes through DeletionManager, the only PHAssetChangeRequest.deleteAssets site; the single documented exception is the compression replace, which becomes one single-transaction swap in WS-43. Live Photo conversion (WS-60) deletes originals through DeletionManager after verification and is not a second exemption. After WS-11 the invariant reads: guardrails, then the iOS system confirmation, with Recently Deleted (30 days) as recovery; code, UI copy and both CLAUDE.md files must agree.
5. PhotoScanEngine generates bounded candidates and the policy services classify and rank them. ConservativeKeeperRankingService is authoritative; Core ML stays optional, lazy, never loaded on the main actor, fallback-safe (confidence 0.85, margin 0.15), and no model ships in v1.
6. The keeperMargin < 0.08 downgrade is a safety rule and survives removal of preference-driven downgrades; the only exemption is clusters verified identical by DuplicateVerificationService (SCAN-04).
7. Automated plans (Keep Best, Auto-clean, inferred plans, burst extras) never include favorites, user-kept IDs, user-pick burst frames or undeletable assets. User-authored actions (swipe, manual single or multi select) may delete favorites; bulk select-all excludes them.
8. Screenshots never mix with camera photos; screenshot, blurry, video and other category grids never pre-select anything.
9. Lifetime stats and feedback are recorded only after PhotoKit confirms deletion.
10. Never collect review effort and then paywall its commit: paid gates appear before selection effort, and every gate goes through CleanupAccessPolicy after WS-36.
11. Scans never use the network by default; iCloud download requires explicit opt-in. Unanalyzed assets are tracked separately and never counted as coverage or reported as a clean library.
12. Vision feature-print revision stays pinned; embedding byte count and version are validated; RMS normalization is shared; analysis-semantics changes bump analyzerVersion or embeddingVersion once, batched (D-REANALYSIS).
13. Scan-run fencing: every worker and supporting-scan MainActor hop checks activeScanID; the run lock (isFinalizingPhotoScan, renamed isPhotoRunActive in WS-28) is held from scan start until the completion snapshot is durable, including after resume; persistCleanupState maps completed-but-finalizing to .scanning and the completion barrier is published last. Preserve verbatim through WS-15, WS-16 and WS-49.
14. Snapshot persistence: PhotoAnalysisCache stays the single writer with generation ordering, newest-only pending writes, atomic writes and a backup that is never overwritten by an older generation (memoization in WS-17 and zero-copy rotation in WS-54 must keep this); hasConsistentCompletionState is never loosened; the planner returns nil (full plan), never an empty work set, on inconsistency; reconcile never writes a snapshot before hydration; a completed snapshot records only the inventory its run covered; ML retention never runs against an empty active-library set.
15. Limited Photos access never overwrites or prunes full-library derived state (analysis snapshot, large-video results, ML rows); limited sessions stay in memory (D-LIMITED-ACCESS).
16. Photo and video scans never load PhotoKit concurrently; relaxing the review lock (WS-27) must not change that.
17. The scan update stream stays bounded (bufferingNewest(1)); updates are cumulative, or deltas whose evicted elements are merged into the next yield (D-UPDATE-DELTAS). The engine drains results in strict chronological order (orderedProcessedIDs, genericCandidateIDs early break) and each watchdog slot is released exactly once.
18. Durability boundaries (completion, pause, background) always produce a durable snapshot before returning, whatever the periodic checkpoint cadence.
19. An explicit user Pause is sticky across relaunch; automatic pause/resume, thermal suspension and first-scan auto-start never override user intent or count as a user pause.
20. PhotoKit is never touched while authorization is notDetermined; permission is requested only in context and limited access keeps working everywhere.
21. Images load only through PhotoImageRepository (separate analysis and UI lanes after WS-52); no display path requests PHImageManagerMaximumSize; analysis, review and fullscreen results never evict UI thumbnails from the shared LRU.
22. Performance work never changes classification, keeper choice or deletion semantics.
23. PurchaseManager: Transaction.updates listener at launch; verified and unverified transactions finished; inconclusive checks never revoke; only a verified revocation downgrades; price only from Product.displayPrice; keep the EntitlementSource seam.
24. Export: copy, verify (hash for deletion eligibility after WS-05), manifest, then an explicit delete of verified IDs through DeletionManager; failures leave Photos untouched; re-check album membership before deleting.
25. Compression: refuse output that is not smaller, refuse estimated original sizes, keep temp-file leases and the orphan sweep, and preserve creationDate, location and favorite (plus albums after WS-43).
26. Diagnostics stay opt-in and sanitized (no asset IDs, filenames, paths or localized errors); only elapsed-time values leave the device. UNUserNotificationCenter's delegate stays installed in App.init with foreground presentation suppressed.
27. Release builds contain no DEBUG admin unlock, ML export or fixture analyzer code. Keep SWIFT_STRICT_CONCURRENCY=complete, zero warnings (enforced in CI after WS-06) and zero SPM dependencies.
28. HomeViewModel remains the single facade with an unchanged view API through the decomposition; new pure types go in new files, each added to project.pbxproj.
29. Do not redesign Duck Mode, Files, Paywall or Onboarding visuals (design handoff pending). Functional changes use existing Duck components and the accentPrimary token (not Color.accent); the only visual exception is the owner-confirmed contrast-token change in WS-56 (D-CONTRAST).

---

## 6. Decision log

These are the defaults Sonnet follows. Decisions marked **Owner** are ones the owner should confirm, ideally before the listed workstreams start. If there is no answer, proceed with the default and say so in the PR summary.

### D-UNDO · Owner
**Question:** Restore the 10-second deferred undo window, or retire it and treat the iOS confirmation plus Recently Deleted as the undo?

- **Default:** Retire the window: immediate PhotoKit commit after guardrails, iOS system confirmation, a post-commit receipt toast, Recently Deleted (30 days) as recovery
- **Why:** PhotoKit already forces a system confirmation on every delete and Recently Deleted keeps items 30 days. Deferring that dialog 10 s makes it appear out of context and it cannot be shown while backgrounded. Today's shipped UX is already immediate; retiring removes about 150 lines of dead state and makes code, copy and CLAUDE.md agree. Add an in-flight guard, typed .declined results and a receipt toast. Owner: confirm before WS-11; Sonnet proceeds with the recommendation if no answer.
- **Alternatives considered:** Restore the coalesced 10 s window for multi-item and automated paths, with cancel-and-restore on backgrounding
- **Affects:** WS-11, WS-12, WS-35, WS-43

### D-FREE-KEEPBEST · Owner
**Question:** Is classifier Keep Best free on every group, or limited to one lifetime group (literal reading of CLAUDE.md line 65)?

- **Default:** Unlimited per-group Keep Best free. Reword CLAUDE.md to 'classifier-selected Keep Best, one group at a time'.
- **Why:** The workspace CLAUDE.md says free users can complete classifier-selected Keep Best, FIXSPEC 0.3 is marked done this way, and ROADMAP insists on a real free tier. Each group still costs one tap plus a system prompt, so Auto-clean all keeps clear paid value. Owner: confirm before WS-36 (WS-04 already assumes it).
- **Alternatives considered:** Unlimited per-group Keep Best free; Auto-clean all is the paid bulk / One free Keep Best group, then Pro (UI-05)
- **Affects:** WS-04, WS-36

### D-GATING · Owner
**Question:** Which manual deletions require Pro?

- **Default:** Keep the CLAUDE.md model, made coherent. Free: any single item everywhere; any strict subset of a classifier recommendation; a keeper swap that does not increase the delete count; Duck Mode commits including a screenshot/blurry swipe queue; verified Export & Delete. Pro: Auto-clean all; manual multi-select of more than one item outside those cases (category Select All or Month, large-video and screen-recording multi-delete, Export Album 'Delete N without export', custom group selections beyond the recommendation); video compression; Live Photo conversion of more than one item. The lock shows before the second selection or on Select All, never at commit.
- **Why:** Preserves the documented paid value (bulk custom selection), removes the safety-adverse incentive of paying to delete less, closes the Export Album back door and follows the 'never paywall collected effort' rule; free users still get a real bulk path through swipe review. Owner: confirm before WS-36.
- **Alternatives considered:** Only Auto-clean all and compression are paid; every user-authored selection is free (STORE-06 primary) / Keep the CLAUDE.md model: custom multi-select (>1) is Pro, made coherent
- **Affects:** WS-04, WS-36, WS-41, WS-42, WS-60

### D-EXPORT-DELETE · Owner
**Question:** Is deleting originals after a verified export (Export Album and Large Videos export) free?

- **Default:** Free. Record it explicitly in CLAUDE.md.
- **Why:** It is the backup-then-remove flow, the safest way to free the most bytes, and the user has already invested export effort; paywalling it after that effort breaks the review-effort rule. Owner: confirm together with D-GATING before WS-36.
- **Alternatives considered:** Free, because it follows a user-authored, hash-verified copy / Pro when more than 1 item, like multi-select
- **Affects:** WS-35, WS-36

### D-IPAD · Owner
**Question:** Support iPad in v1?

- **Default:** iPhone-only for v1.
- **Why:** No iPad layout exists or has been tested; universal with portrait-only fails upload validation; iPhone-only removes iPad screenshots and review surface. Owner: confirm before WS-02.
- **Alternatives considered:** iPhone-only (runs on iPad in compatibility mode) / Full iPad support with all orientations and adaptive layouts
- **Affects:** WS-02

### D-MIN-OS · Owner
**Question:** Minimum iOS version?

- **Default:** Raise to iOS 17.0.
- **Why:** 16.x has never been run or tested. iOS 17 gives VNRequest.setComputeDevice for the Vision CPU fallback, removes the 16.2 ActivityKit branches and only drops iPhone 8/8 Plus/X. PHPersistentChange (WS-18) exists since iOS 16 either way, and BGContinuedProcessingTask (WS-29) is iOS 26 behind #available regardless. The owner previously invested in iOS 16 compatibility (commits 434aea8, 5211e39). Owner: confirm before WS-06; if overriding, set the app to 16.2 and add the 16.4 CI destination.
- **Alternatives considered:** Raise to iOS 17.0 for all targets / Stay at 16.0 (app) / 16.2 (widget) and add an iOS 16.4 simulator CI destination
- **Affects:** WS-06, WS-22, WS-29

### D-ML · Owner
**Question:** What ML/learning footprint ships in Release v1?

- **Default:** No training collection in Release (DEBUG or PHOTODUCK_ML_COLLECTION flag only). Bounded warm cache of the 10k newest embeddings in Caches/PhotoDuck/ml. Pair cache removed. Legacy Application Support/PhotoDuck/ml deleted on upgrade. No model bundled. The JSON feedback journal stays on because preference priority uses it.
- **Why:** The collected rows are unusable (train/serve skew, never-written tables), cost 0.6-0.7 GB on the devices that most need space, and give users nothing. The warm cache keeps incremental scans fast. Owner: confirm before WS-33.
- **Alternatives considered:** No training collection in Release; embeddings kept only as a bounded, backup-excluded warm cache in Caches; pair cache removed; no Core ML model bundled / Keep full collection in Release for a future model
- **Affects:** WS-33, WS-46, WS-48

### D-PREFS · Owner
**Question:** May learned preferences change a group's action or confidence in v1?

- **Default:** No action or confidence changes from preferences in v1; priority-only with at least 8 decisions; keep the margin rule.
- **Why:** The current aggregates count automation as human keeps and manual deletes as rejections, which silently strips Keep Best after one Auto-clean run. Removing the mutations is the only safe v1 fix. Engineering default; no owner confirmation needed.
- **Alternatives considered:** No: preferences may only adjust queue priority, gated by a minimum sample; keep the keeperMargin<0.08 safety downgrade / Yes, with a minimum sample size (SCAN-M01)
- **Affects:** WS-33

### D-BACKUP · Owner
**Question:** Which PhotoDuck data is backed up?

- **Default:** Exclude the whole directory, flagged at the directory level at every launch before any store opens. UserDefaults (entitlement cache, lifetime stats, onboarding, cleanup-state scalars) stays backed up.
- **Why:** Everything in that directory is regenerable or keyed by device-specific localIdentifiers. The directory-level flag survives the atomic writes these stores use. WS-15's CleanupStateReconciler makes the restored-device case (UserDefaults present, snapshot absent) show 'run a new scan' instead of phantom counts. Engineering default; owner FYI.
- **Alternatives considered:** Exclude the whole Application Support/PhotoDuck directory (caches, snapshots, feedback, preferences, keep decisions); keep UserDefaults backed up / Exclude caches only; back up feedback, preferences and keep decisions
- **Affects:** WS-12, WS-34

### D-PRICING · Owner
**Question:** Launch price for the one-time unlock?

- **Default:** $19.99 lifetime with a $14.99 launch promo, set in App Store Connect; mirror it in the local .storekit for testing. No grandfathering needed if no public build has shipped.
- **Why:** No code depends on the price (Product.displayPrice) and ROADMAP's competitive analysis supports it. Owner decision in App Store Connect before WS-58; does not block engineering.
- **Alternatives considered:** $2.99 (current local .storekit) / $9.99 / $19.99 lifetime with a $14.99 launch promo (ROADMAP)
- **Affects:** WS-58

### D-SCOPE · Owner
**Question:** Which reclaim categories are in v1?

- **Default:** v1: videos-first plus freshness, all-video thresholds and kinds with screen recordings of any size (PHAssetMediaSubtype.videoScreenRecording), large-video multi-delete, video export-then-delete, burst extras, bulk screenshots/blurry with free swipe, Recently Deleted guidance, verified identical-copy Keep Best, first scan auto-started from onboarding. M4: Live Photo measurement and still conversion, RAW/48 MP, cross-date identical copies, duplicate videos by frame-hash verification, similarity presets, retention loop
- **Why:** The v1 set reuses existing seams and has the best GB per unit of effort (videos are usually most library bytes; screen recordings are a safe free-tier win). The M4 items need the measurement, verification and entitlement layers to have proven themselves on devices. Option 3 is the cheapest upgrade if the owner wants Live Photo visibility at launch. Owner: confirm before WS-42.
- **Alternatives considered:** Everything in v1 / Option 1 plus Live Photo measurement only (WS-59's Live Photo part) pulled into v1
- **Affects:** WS-40, WS-41, WS-42, WS-59, WS-60, WS-61, WS-62, WS-63, WS-64

### D-BACKGROUND
**Question:** How much background execution in v1?

- **Default:** Idle-timer disable during active foreground scans plus honest copy, BGContinuedProcessingTask for user-initiated scans on iOS 26+, and otherwise a clean pause on background (D-SCAN-CONTINUITY); hide 'Notify me' unless a continuation was scheduled. The screen stays awake only while thermal state is .fair or better. BGProcessingTask-while-charging is an optional follow-up inside WS-29.
- **Why:** The idle timer fixes the most common failure (screen auto-lock); BGContinuedProcessingTask is the supported way to keep a user-started long task alive on iOS 26; pausing cleanly on background avoids the unanalyzed-after-suspension and lease-overrun failures in STATE-07. Engineering default.
- **Alternatives considered:** Also schedule BGProcessingTask (requires external power) on iOS 17-25 / Foreground only; remove 'Notify me'
- **Affects:** WS-28, WS-29

### D-MIGRATION
**Question:** What to do with the uncommitted legacy per-run export-folder migration?

- **Default:** Merge by reference, with no file moves.
- **Why:** Keeps one dedupe history with zero risk of losing export records or reorganizing the user's drive; manifest resolution already supports subpaths. Engineering default.
- **Alternatives considered:** Merge legacy manifests by reference (relative paths), no file moves / Keep moves but make them safe (verify the merged manifest before deleting each folder, propagate errors, ask the user) / Delete the migration if no public build shipped the per-run layout
- **Affects:** WS-05

### D-COMPRESSION · Owner
**Question:** Compression output format and default preset?

- **Default:** HEVC 1080p default and .mov with metadata passthrough.
- **Why:** Fewer surprising quality losses on a destructive paid action, camera metadata survives, and tiny savings that are not worth a re-encode are refused. Engineering default; owner may override the quality default.
- **Alternatives considered:** HEVC 1080p default; output .mov with metadata passthrough; hide 'Maximum quality' for sources already HEVC; require at least 10% and at least 20 MB savings / Keep the 720p H.264 default and .mp4
- **Affects:** WS-43, WS-44

### D-GIT · Owner
**Question:** How to consolidate the repositories?

- **Default:** Nested repo: commit WIP, fast-forward main to feat/ml-training-pipeline, archive origin/main under a tag and branch, then merge -s ours (no force-push); outer repo: detach its .git and delete the stale app copy after user confirmation. Sonnet prepares the commands; pushes, remote branch changes and any outer-repo deletion wait for explicit user approval.
- **Why:** Nothing unique is lost (all refs stay reachable), there is no destructive force-push, and GitHub's default branch then shows the real app. Owner approval required for every push, remote-branch change and outer-repo change.
- **Alternatives considered:** Force-update origin/main
- **Affects:** WS-01

### D-REANALYSIS
**Question:** How to roll out analyzer changes (edit detection, blur, orientation, confirmation signals) that invalidate cached analysis?

- **Default:** One batched bump in WS-37. WS-22, WS-24 and WS-38 must not bump analyzerVersion.
- **Why:** Each bump forces a full-library re-analysis (hours on 60k libraries). Recomputing live signals avoids a bump for SCAN-10 entirely. Engineering default.
- **Alternatives considered:** Batch all analyzer-affecting changes into one analyzerVersion bump (WS-37), and recompute favorite and edited signals from the live PHAsset in makeGroups instead of caching them / Bump per change
- **Affects:** WS-22, WS-37, WS-38

### D-THRESHOLDS
**Question:** What evidence is required before changing similarity thresholds?

- **Default:** Verify-first: a calibration fixture test (synthetic or CC0 images only) plus a DEBUG distance histogram from a device run; loosen only after real blur (WS-37) and verification (WS-38) land
- **Why:** Loosening near-duplicate thresholds makes keeper choice decisive for destructive plans; it is only safe once blur is measured correctly and pixel/text verification guards the destructive path. Engineering default.
- **Alternatives considered:** Adjust from ROADMAP's ~11 raw note now
- **Affects:** WS-39, WS-63

### D-FAVORITES-USER · Owner
**Question:** Can users delete favorited photos through their own actions?

- **Default:** Yes for single, manual multi-select and swipe decisions; never in automated plans; excluded from Select All and from Live Photo conversion by default
- **Why:** Favorites are a strong 'keep' signal for automation, but blocking user-authored intent would be paternalistic; the iOS confirmation still applies. Engineering default; owner may override.
- **Alternatives considered:** Never deletable in-app
- **Affects:** WS-13, WS-41, WS-60

### D-PRIVACY-URL · Owner
**Question:** Where are the privacy policy and support pages hosted?

- **Default:** GitHub Pages with a mailto support address; code uses a PhotoDuckLinks placeholder constant until the owner supplies the domain and email.
- **Why:** App Store Connect requires a Privacy Policy URL and a Support URL; a static page keeps the no-backend identity. Owner supplies the domain and support email before WS-48.
- **Alternatives considered:** GitHub Pages (or equivalent static page) with the same text as the in-app policy; mailto support address / No hosted page
- **Affects:** WS-48, WS-58

### D-DIAG-UPTIME
**Question:** Keep using raw ProcessInfo.systemUptime in diagnostics?

- **Default:** Session-elapsed seconds plus the 35F9.1 declaration, a schema v2 envelope, and deletion of the v1 ring file.
- **Why:** 35F9.1 permits only elapsed time to leave the device; this is the smallest change that makes the manifest truthful. Engineering default.
- **Alternatives considered:** Replace it with session-elapsed seconds (a per-launch baseline) and keep the SystemBootTime 35F9.1 declaration / Drop SystemBootTime use entirely and use Date ordering
- **Affects:** WS-02

### D-HVM-DECOMP · Owner
**Question:** When and how to decompose the 2,640-line HomeViewModel?

- **Default:** Behavior-preserving extraction in phases ahead of the state fixes: phase 0 seam in M0 (WS-07); phases 2-4 (WS-15) and 5/7/8 (WS-16) before the launch, inventory, snapshot and reconcile fixes; phase 6 with the inventory (WS-18); phase 1 with ScanOutcomeSummary (WS-31); phase 9 coordinator last in M3 (WS-49), cuttable
- **Why:** About 25 workstreams touch this file and the STATE/PERF fixes need HomeViewModel-level tests (injected engine factory, temp stores). Extracting first turns each later fix into an edit of a small, testable type; one PR per 2-3 phases keeps diffs reviewable; a golden AnalysisSnapshotBuilder test and the unchanged view API make each step verifiable. The riskiest phase (coordinator) waits until the lifecycle fixes are in and is optional for v1. Engineering default; no owner confirmation needed.
- **Alternatives considered:** Fix bugs in place first and extract after v1 / One big-bang extraction PR
- **Affects:** WS-07, WS-15, WS-16, WS-18, WS-31, WS-49

### D-LIMITED-ACCESS
**Question:** What may PhotoDuck persist or prune while Photos access is Limited?

- **Default:** In-memory only: no snapshot or large-video cache writes and no ML inactive-asset pruning under .limited; restore the full-access snapshot read-only; on Limited to Full, rehydrate and run an incremental pass. Home says 'Results cover the N photos you shared with PhotoDuck.'
- **Why:** Selections are small, so re-analysis each launch is cheap, while today's behavior silently deletes hours of full-library analysis and all prior findings when a user tries Limited. A separate file adds a second consistency model for little gain. Engineering default.
- **Alternatives considered:** Keep a separate limited-session snapshot file / Treat Limited as a smaller library (current behavior)
- **Affects:** WS-20, WS-46, WS-48

### D-SCAN-CONTINUITY · Owner
**Question:** Should scans continue automatically across backgrounding, termination and first launch?

- **Default:** Yes: auto-pause the engine on background (unless a continued-processing task is running) and auto-resume on return; auto-resume interrupted scans at launch with a 2-attempt, 8-photo-progress crash-loop guard; an explicit Pause stays paused across relaunch; granting access in onboarding auto-starts the first scan as a user-initiated scan
- **Why:** Long first scans are foreground-bound, so interruptions are the norm; today they surface as 'paused' states that users read as finished or broken, and work done after the background checkpoint is lost. Auto-start on grant is ROADMAP playbook #4 (the scan is the demo) and removes a redundant tap. Owner: confirm the onboarding auto-start (a first-run product behavior) before WS-26; Sonnet proceeds with the recommendation if no answer.
- **Alternatives considered:** Manual only: every interruption waits for Continue and the first scan waits for Start
- **Affects:** WS-26, WS-28, WS-29

### D-INVENTORY
**Question:** How does PhotoDuck keep its library inventory current?

- **Default:** One single-flight PhotoLibraryInventory: PHPersistentChangeToken deltas with full-enumeration fallback; refresh only on background to active when the library is dirty or 30 s have passed; the engine consumes the inventory's ordered fetch; missing required IDs are dropped (throw only on an empty or <90% fetch)
- **Why:** Removes 4-5 enumerations per launch and one per Control Center pull, makes plan-time and engine-time asset sets identical (the basis for STATE-01's recorded inventory), and turns a transient iCloud deletion from a failed scan into a reported drop. Engineering default.
- **Alternatives considered:** Keep full enumeration but coalesce and throttle it / Status quo
- **Affects:** WS-18, WS-19, WS-21

### D-RESULTS-FRESHNESS
**Question:** When are results 'stale', and what may lock review?

- **Default:** Stale only when unanalyzed additions or modifications are pending (in-app deletions never make results stale); photo review is never locked by the supporting video pass; only the photo durability window locks completion
- **Why:** Deleting is the point of the app; telling users their cleanup outdated their results nudges them into hours-long rescans. Photo results are durable before the video pass starts. Engineering default.
- **Alternatives considered:** Stale whenever the library count changes, and lock review until the video pass ends (current)
- **Affects:** WS-21, WS-27, WS-45

### D-SCAN-RESOURCES
**Question:** How should long scans adapt to device conditions, and how often should they publish progress and checkpoint?

- **Default:** Adaptive: nominal/fair 8 in flight; Low Power 4 with 50 ms between batches; serious 3 with 250 ms and a 'warm' message; critical suspended until it cools; memory warning within 60 s gives 2 plus flush and purge. Progress publications at most 4 Hz (forced on state and group changes). Checkpoint when elapsed >= max(20 s, 40x last write time, bytes / 256 KB/s) and (>= 500 new photos or groups changed); completion, pause and background always checkpoint. Values are tuning constants that WS-09 and later QA runs may adjust.
- **Why:** Keeps a 30-90 minute scan cool and alive on 3-4 GB devices, respects Low Power Mode, and cuts checkpoint writes from about 5-7 GB to under 1 GB per first 60k scan while losing at most a few hundred photos of cheap-to-redo progress on a crash. Engineering default.
- **Alternatives considered:** Fixed concurrency and a fixed 20 s checkpoint (current)
- **Affects:** WS-25, WS-29, WS-50, WS-54

### D-UPDATE-DELTAS
**Question:** Can scan updates become deltas (SCAN-19) while the stream keeps dropping stale elements?

- **Default:** Yes, with drop-merge: keep bufferingNewest(1); when yield returns .dropped(old), merge old's deltas into the new element and yield again; keep targetAssetIDs on the first update and in checkpoints
- **Why:** Bounded buffering protects a slow main actor, while pure deltas under a dropping buffer would silently lose evaluated IDs. Drop-merge keeps both properties and is testable with a slow consumer. Engineering default.
- **Alternatives considered:** Switch to an unbounded buffer with deltas / Keep cumulative sets and only make the main-actor fold incremental
- **Affects:** WS-53

### D-PERF-GATE
**Question:** Where do scale benchmarks run, and what fails the build?

- **Default:** A separate Performance test plan (not the PR job) run nightly and on performance-labelled PRs; growth-ratio assertions (time(4n)/time(n) < 6) are hard failures; known failures are wrapped in XCTExpectFailure naming the finding until its fix lands; absolute baselines are advisory per simulator
- **Why:** Growth ratios catch quadratic regressions regardless of machine speed, while absolute timings are noisy on shared runners; keeping the plan off the PR path keeps PR CI fast. Engineering default.
- **Alternatives considered:** Run benchmarks on every PR / No automated benchmarks
- **Affects:** WS-06, WS-08, WS-58

### D-CONTRAST · Owner
**Question:** Fix WCAG contrast now or wait for the design handoff?

- **Default:** Now: add text-safe tokens (accentText #B8307A, warningText #996100, successText #1E7A4F, dangerText #B8285A, DuckRose any-appearance to #B04A7C) for all text, and darken the primary CTA gradient, selected pill and bottom action bar so white labels reach at least 4.5:1; brand fills and icons unchanged
- **Why:** Primary CTA labels (2.9:1) and captions (2.7-4.0:1) fail AA on the screens where users make destructive decisions and read disclosures. The change is token-level, so the handoff can restyle freely above the floor that DesignContrastTests enforce. Owner: confirm before WS-56 because it visibly changes the pink on buttons; option 2 is the fallback. Amended in WS-56 (chapter 12): some listed text tokens fail on dark chrome (accentText is about 3.5:1 on black), so WS-56 adds a dark-chrome rule (DuckTone.textOnDark) and also fixes the white-on-danger/success Duck Mode fills.
- **Alternatives considered:** Text tokens now; keep the current CTA gradient until the handoff / Wait for the design handoff
- **Affects:** WS-56

### D-GROWTH · Owner
**Question:** Which retention and growth features ship in v1?

- **Default:** v1: only the App Store review prompt (once per version after a DeletionManager-confirmed cleanup of >= 500 MB or >= 50 items; never after an error, paywall or decline), delivered in WS-58. M4: monthly stats and 'This month' card, recap share card, home-screen widget with an App Group, App Intents, monthly notification
- **Why:** The review prompt is small, uses public API and matters most at launch; the rest needs an App Group entitlement, new widget kinds and more QA, and adds no reclaim value. Owner: confirm before WS-58; the App Group needs owner provisioning in M4.
- **Alternatives considered:** Everything in v1 / Nothing in v1
- **Affects:** WS-58, WS-64

### D-LIVEPHOTO · Owner
**Question:** How and when does PhotoDuck offer Live Photo motion savings?

- **Default:** M4, two steps: measure and disclose (sampled '≈' bytes), then an explicit-selection still conversion that excludes Loop/Bounce, edited, hidden, favorited (default), non-user-library, depth-effect and non-local items, converts in chunks of at most 25, verifies before deleting originals through DeletionManager, and journals created stills so a declined prompt never leaves silent duplicates; one item free, more than one Pro
- **Why:** Likely the largest photo-side reclaim, but conversion irreversibly removes motion and sound; it should follow the proven measurement, deletion and entitlement layers and ship after v1 device QA. FSB-01's exclusions protect user-chosen effects, edits and hidden-photo privacy. Owner: confirm scope and gating before WS-59 (optionally pull measurement into v1 per D-SCOPE option 3).
- **Alternatives considered:** Measure only, never convert / Build conversion in v1
- **Affects:** WS-59, WS-60

### D-SENSITIVITY
**Question:** Offer user-selectable similarity sensitivity?

- **Default:** M4: 'Standard' and 'Strict' presets that only hide or trim review-only 'Similar' groups, using pair evidence stored with each group (WS-63). No re-clustering, no Vision work, and never any change to Keep Best or auto-clean plans. Threshold revisions apply on the next user-initiated full re-analysis (contract 13). Any future 'Aggressive' preset stays review-only.
- **Why:** Gives users a lever on the category's top complaint without ever changing destructive plans; builds on WS-39's injectable threshold profile. Engineering default.
- **Alternatives considered:** Expose all thresholds / No presets
- **Affects:** WS-39, WS-63


---

## 7. Milestones and workstream status

### M0 — Foundation, upload blockers, stop-ship fixes and dev loop
One git source of truth; a Release archive uploads to TestFlight; the three live P0 data-safety bugs are fixed; DeletionManager and HomeViewModel are testable; CI, a simulator fixture path, engine safety nets and scale benchmarks exist; a real-device baseline is recorded; giant view files are split.

Workstreams: WS-01, WS-02, WS-03, WS-04, WS-05, WS-06, WS-07, WS-08, WS-09, WS-10

Exit criteria:
- Nested repo: WIP committed; main contains feat/ml-training-pipeline; the prototype line is archived under a tag; git status is clean; stray assets removed and .gitignore updated (pushes and outer-repo changes only with explicit user approval).
- A Release archive passes Organizer Validate and uploads to TestFlight with no ITMS-91053 or ITMS-90474; the Privacy Report categories match PrivacyInfo.xcprivacy and PrivacyManifestLintTests passes.
- Group-detail commit-policy tests prove no ID outside the displayed deleteSet is ever deleted; Duck cards are keyed by asset ID; a cancelled GOPR0001.MP4 followed by a different same-named asset never splices, and deletion eligibility requires a hash match.
- DeletionManagerTests cover keeper exclusion, visuallySimilar rejection, dedupe, cancel (3072) without stats, failure without stats and success stats; the unit-test host creates no app managers and no test writes to the shared ML store.
- HomeViewModel is constructed in a unit test through HomeViewModelDependencies (temp UserDefaults suite, temp caches, observesPhotoLibrary false); the verified-dead members are gone; iOSCleanupApp owns the @StateObject.
- GitHub Actions runs unit tests plus a Release build with SWIFT_TREAT_WARNINGS_AS_ERRORS=YES on every PR; 3 consecutive green runs with no sleep-based tests remaining.
- In the simulator with -PhotoDuckFixtureAnalyzer and seeded fixtures, a scan yields at least 1 auto-clean-eligible group and 0 unanalyzed photos, and Keep Best and Duck Mode are reachable end to end.
- FSB-05's five end-to-end engine tests pass (a near-duplicate pair produces explicit keeper and delete IDs; visuallySimilar has no delete candidates); write-buffer, pause-flush and progress-monotonic tests pass; `xcodebuild test -testPlan Performance` finishes in under 3 minutes with committed baselines, and only the known PERF-01 and PERF-13 growth ratios are wrapped in XCTExpectFailure.
- docs/DEVICE_QA.md exists and a baseline run on at least one real device with a library of 10k or more is recorded: time to hydrated Home, time to first group, total time, photos/s with p50/p99 item latency, analyzed/unanalyzed/groups, peak memory, snapshot bytes, checkpoint bytes per minute, thermal state after 30 minutes, and the verify-first observations (DEL-06, SCAN-10, SCAN-14, SCAN-21, SCAN-05 histogram, STATE-01 mid-scan add, STATE-02 Limited round trip, STATE-07 background round trips).
- No file in Views/Files exceeds about 600 lines; ExportAlbumView, PhotoCategoryReviewView and CompletionOverlay live outside HomeView.swift; the suite and the simulator smoke test pass unchanged.

### M1 — Core reclaim loop works safely, consistently and honestly on a real device
On a real 10k-60k iCloud library a user can scan (videos first) at full throughput, keep scanning across lock, background and relaunch, review, delete safely and see truthful numbers; scan state stays consistent across library changes, Limited access and restarts; launch is fast; automation never touches protected photos; PhotoDuck's own storage no longer inflates backups.

Workstreams: WS-11, WS-12, WS-13, WS-14, WS-15, WS-16, WS-17, WS-18, WS-19, WS-20, WS-21, WS-22, WS-23, WS-24, WS-25, WS-26, WS-27, WS-28, WS-29, WS-30, WS-31, WS-32, WS-33, WS-34, WS-35

Exit criteria:
- Code, UI copy and both CLAUDE.md files agree on deletion semantics (no 'undo window' or '10 seconds' strings). DeletionManager exposes one API per action returning DeletionResult; declining the iOS prompt shows no error on any surface; concurrent deletes are rejected (tested).
- Guardrail tests prove automated plans exclude favorites (live value at commit), user-kept IDs and undeletable assets, and that a group whose keeper vanished is skipped. Duck Mode has no exit path that discards pending decisions without confirmation.
- HomeViewModel extraction phases 2-5, 7 and 8 landed with no view changes; the AnalysisSnapshotBuilder golden test is byte-identical to the pre-move output; CleanupStateStore, PhotoResultsStore and LargeVideoScanController have unit tests.
- Launch: at most one analysis-snapshot decode (DEBUG decodeCount); restoring 5,000 groups / 15,000 members takes under 300 ms on an iPhone 12; the CTA never offers 'Scan again' while saved results load; after deleting Application Support/PhotoDuck, Home shows 'run a new scan', never a nonzero group count over empty lists.
- Snapshot integrity: adding a photo during a Deep Clean leaves a consistent snapshot, relaunch shows the completed state with no storage warning, and the next launch analyzes exactly that photo; existing poisoned snapshots are repaired without a full rescan; a Full to Limited to Full round trip leaves photo-analysis-cache.json, large-video-results.json and the ML photo_features row count unchanged.
- Inventory: a cold launch with an unchanged library performs no full enumeration; Control Center and notification-shade pulls trigger none; a required photo deleted between planning and fetch no longer fails the scan.
- Reconciliation: photos deleted mid-scan disappear from every surface within one update; nothing published during a reconcile is removed unless PhotoKit reported it missing; in-app deletions never mark results stale; granting permission after denial goes straight to a scan.
- Engine: unanalyzed photos report reason counts; 'Download and Rescan' appears only when imageNotLocal dominates; Vision failures retry on CPU; a new target is compared with context older than 480 positions; output groups are pairwise disjoint (DEBUG assertion); resident embeddings stay at or below 4,096 during a large retry pass.
- Throughput: on the baseline device, photos/s is at least 2x the WS-09 baseline whenever p99 item latency exceeds 10x p50, with identical groups on the deterministic fixture; under Serious thermal state in-flight analyses drop to 3 or fewer with an explanation, and under Critical the scan pauses then resumes automatically without losing progress.
- Orchestration: on a user-initiated first scan, Large Videos appear before the photo Deep Clean finishes; new videos appear after 6 h or a count change; the completion sheet never appears for automatic scans; photo review stays available during the video pass; granting access in onboarding lands on a running scan.
- Continuity: after pause and resume the completion sheet's first render shows the new run's counts; backgrounding mid-scan checkpoints the engine's committed count and resumes automatically, and 20 app switches add no unanalyzed photos; a scan stopped from Xcode resumes on relaunch; an explicit Pause survives relaunch; the screen does not auto-lock during an active foreground scan; 'Notify me' appears only when a background continuation was scheduled.
- Device QA on a 30-60k iCloud 'Optimize iPhone Storage' library: the scan completes (foreground, plugged in) with no jetsam; Home shows on-device and iCloud-only bytes separately; after Keep Best on N groups and emptying Recently Deleted, the Settings free-space delta is within ±20% of PhotoDuck's on-device figure.
- Completion sheet, hero, CTA, empty states and completion notifications all derive from ScanOutcomeSummary (tests for findings, nothingFound, incomplete and analysisFailed); 'Cleanup complete' or 'looks clean' never appears when unanalyzed > 0; authorized users never see 'Notify me' during a launch scan, and each alert opens the screen its text describes, including from a cold launch.
- Release build writes no training rows; a test asserts isExcludedFromBackup on Application Support/PhotoDuck; a test proves preference data cannot downgrade keepBestTrashRest; at the 1,000-event steady state a swipe performs no feedback-archive rewrite.
- Export & Delete deletes only archival-mode, hash-verified assets, and the Large Videos export offers a verified delete.

### M2 — High-yield reclaim and a coherent free/paid model
Keep Best actually fires on real duplicates and is safe when it does. Bursts, screenshots, screen recordings and videos can be cleared in bulk. Compression is safe and useful. Every paid gate follows one tested policy.

Workstreams: WS-36, WS-37, WS-38, WS-39, WS-40, WS-41, WS-42, WS-43, WS-44, WS-45

Exit criteria:
- Every paid gate calls CleanupAccessPolicy (grep finds no inline isPurchased checks outside the policy and paywall); policy unit tests encode D-GATING; StoreKitTest tests cover purchase, refund, Ask to Buy approval and restore; VideoCompressionView refuses to start without the entitlement even when presented directly.
- Fixture tests: verified identical copies become isAutoCleanEligible through the engine (the WS-08 identical-copies pin is flipped); document and receipt pairs with differing text or tiles are review-only; unavailable verification stays review-only.
- One analyzerVersion bump shipped; the blurry category is gated on edge density; keeper sharpness is measured at native resolution of at least 1024 px.
- Calibration test and device histogram committed; thresholds change only with recorded distributions (or the PR documents that current values hold); the threshold profile is an injectable value type.
- Burst-extras groups appear with every userPick frame protected (BurstExtrasPlanner tests); inventory, reconcile and resume use the shared fetch-options factory.
- A free user can clear 500 screenshots with one commit via swipe review; Pro Select All/Month works with the lock shown before selection.
- Large Videos offers threshold chips and video kinds, Pro multi-delete with one system prompt, and slo-mo sizes measured from the original; the in-app Screen recordings count matches the Photos Screen Recordings album and recordings under 100 MB are listed and deletable.
- Device QA: declining the compression prompt leaves the library unchanged; albums, date, location and favorite are preserved; compression survives screen auto-lock or reports 'interrupted' with Resume; the preflight no longer refuses local videos that fit.
- Home tiles are sorted by device-reclaimable bytes with ≈ badges, the primary CTA never pauses a scan, and the first-launch hero/CTA duplication and tiles-under-tab-bar layout issues are gone.
- Device QA: time from onboarding to first GB moved to Recently Deleted is 5 minutes or less on a 10k library with videos.

### M3 — App Store readiness and performance at scale
Small own footprint, accurate privacy surface, smooth and stable at 50-60k assets (rendering, images, engine, disk writes), accessible and legible destructive flows, resilient export, and a clean submission.

Workstreams: WS-46, WS-47, WS-48, WS-49, WS-50, WS-51, WS-52, WS-53, WS-54, WS-55, WS-56, WS-57, WS-58

Exit criteria:
- PhotoDuck's on-disk footprint is 160 MB or less after a full scan of a 50k library, measured in WS-54's Device QA (if it is over budget, lower PhotoEmbeddingCachePolicy.capacity from 10,000 in steps of 2,500, minimum 5,000) (Storage & data sheet); the legacy Application Support ml directory is removed on upgrade and the pair cache is gone; ML failures never surface raw SQL to users.
- Privacy Policy, Terms, Restore, Support and Storage & data are reachable from a Home menu by purchasers; a hosted policy URL is entered in App Store Connect; policy copy matches actual data handling including Limited access; no custom priming button says 'Allow'; PHPhotoLibraryPreventAutomaticLimitedAccessAlert is set.
- 60k-asset device scan: no jetsam, no main-thread hang over 250 ms, partial groups refresh at least every 15 s, checkpoint writes never decode snapshots, total checkpoint JSON under 1 GB over a 60-minute scan, and asset-file-sizes-v1.json written at most once per 2 s during the video pass.
- Rendering: progress publications are 4 per second or fewer; during a scan HomeView bodies evaluate 5 times per second or fewer and FileResultsView/SimilarPhotosDashboardView 0 times while another tab is selected; PhotoResultsView body under 2 ms at 5,000 groups.
- Images: no display path requests PHImageManagerMaximumSize; Compare on a 48 MP photo peaks under 80 MB and does not reload the group grid's thumbnails; a 40-photo burst group scrolled fully stays under 120 MB above baseline; the next Duck Mode card is usually displayed by the end of the swipe; flinging a 10,000-item grid during a scan leaves no stuck spinners.
- HomeViewModel is about 700 lines of forwarding and composition with a tested PhotoScanCoordinator (unless WS-49 was cut, recorded in the release notes).
- VoiceOver can complete Keep Best, Delete Selected and Duck Mode flows; at accessibility Dynamic Type sizes onboarding CTAs are reachable; open group details never pop during a scan.
- DesignContrastTests pass and the Accessibility Inspector contrast audit is clean on Home, Similar, Group detail, Duck Mode and Paywall; pills, Pause/Continue, Restore, Privacy, Terms and Skip have hit areas of at least 44x44 pt; no UI string shows '1 photos', '1 groups', '1 videos' or 'bounded'; one radius/spacing token set remains.
- Export: a drive-full condition stops the run with clear copy, Cancel acts within one resource on downloads, and an interrupted export can be resumed from a banner.
- Versions come from build settings; README, both CLAUDE.md files and the StoreKit description are accurate; docs/AppReviewNotes.md exists; unused imagesets removed.
- The Performance test plan is green with no XCTExpectFailure wrappers left; a TestFlight build passes the full DEVICE_QA checklist, Organizer Validate and the Privacy Report, and is submitted for review.

### M4 — Post-v1 growth categories and retention
Add high-yield categories and a retention loop that build on the proven measurement, verification, deletion and entitlement layers.

Workstreams: WS-59, WS-60, WS-61, WS-62, WS-63, WS-64

Exit criteria:
- Live Photo motion-clip bytes are shown as a measured or sampled '≈' opportunity with an explainer; converting 50 local, unedited Live Photos yields stills with identical date, location, favorite, hidden state and album membership with the originals in Recently Deleted; Loop, Bounce, edited and hidden Live Photos are never offered by default; a declined prompt never silently leaves duplicates.
- A 'RAW & 48 MP photos' category is listed by measured size, with deletion under the entitlement policy.
- Identical copies saved on different dates are high-confidence only when verification is .identical; a clip and its WhatsApp-saved re-encode appear as one review-only group with both sizes shown, while different clips of the same length are not grouped; verification never downloads iCloud originals without opt-in.
- Standard/Strict presets apply to a 10k–50k library in under a second, with zero Vision calls and zero image loads. They only hide or trim review-only groups and never change any Keep Best or auto-clean delete plan.
- Monthly stats, the 'This month' card, an honest recap share card, a home-screen widget that updates after scans, and a Siri phrase that opens Screenshots review all work (the review prompt shipped in v1 if D-GROWTH was accepted).


### Workstream index and status

Status values: `todo` · `in-progress` · `done` · `blocked (reason)` · `needs device QA`.

| WS | Workstream | Track | Ms | Size | Verify-first | Depends on | Chapter | Status |
|---|---|---|---|---|---|---|---|---|
| WS-01 | Repo consolidation and WIP commit | A | M0 | S |  | — | [01](01-foundation-upload-blockers-p0s.md) | done 2026-10-04 (local; pushes and outer-repo retirement await owner approval) |
| WS-02 | App Store upload blockers | A | M0 | S |  | WS-01 | [01](01-foundation-upload-blockers-p0s.md) | todo |
| WS-03 | Test foundation: DeletionManager seam, isolated test host, shared doubles | A | M0 | M |  | WS-01 | [01](01-foundation-upload-blockers-p0s.md) | todo |
| WS-04 | P0 photo-review hotfixes | A | M0 | M |  | WS-03 | [01](01-foundation-upload-blockers-p0s.md) | todo |
| WS-05 | Export integrity (Export & Delete data-loss fixes) | A | M0 | L |  | WS-01, WS-03 | [01](01-foundation-upload-blockers-p0s.md) | todo |
| WS-06 | CI, test plans and deterministic tests | A | M0 | M |  | WS-03 | [02](02-dev-loop-ci-fixtures-baseline.md) | todo |
| WS-07 | Simulator fixture harness and HomeViewModel dependency seam | A | M0 | M |  | WS-03, WS-06 | [02](02-dev-loop-ci-fixtures-baseline.md) | todo |
| WS-08 | Engine safety nets: end-to-end groups, lifecycle tests, scale benchmarks | A | M0 | L |  | WS-06, WS-07 | [02](02-dev-loop-ci-fixtures-baseline.md) | todo |
| WS-09 | Device QA plan, signposts and baseline run | A | M0 | M | yes | WS-02, WS-07 | [02](02-dev-loop-ci-fixtures-baseline.md) | todo |
| WS-10 | Mechanical decomposition of giant view files | A | M0 | L |  | WS-04, WS-05, WS-06 | [02](02-dev-loop-ci-fixtures-baseline.md) | todo |
| WS-11 | Deletion core: one honest deletion API | A | M1 | L | yes | WS-03, WS-04, WS-10 | [03](03-safe-deletion.md) | todo |
| WS-12 | Bulk commit flows: Duck Mode lifecycle, remembered keeps, Auto-clean batching | A | M1 | L |  | WS-11 | [03](03-safe-deletion.md) | todo |
| WS-13 | Automated-plan protections: favorites, undeletable assets, album curation | A | M1 | M | yes | WS-08, WS-11 | [03](03-safe-deletion.md) | todo |
| WS-14 | Trustworthy previews | A | M1 | M |  | WS-04, WS-10 | [03](03-safe-deletion.md) | todo |
| WS-15 | HomeViewModel extraction I and restore consistency | A | M1 | L |  | WS-07, WS-12 | [04](04-dashboard-state-and-library-consistency.md) | todo |
| WS-16 | HomeViewModel extraction II and off-main snapshot build | A | M1 | L |  | WS-15 | [04](04-dashboard-state-and-library-consistency.md) | todo |
| WS-17 | Launch restore: linear rehydrate, one decode, no phantom rescan | A | M1 | M |  | WS-08, WS-16 | [04](04-dashboard-state-and-library-consistency.md) | todo |
| WS-18 | Photo library inventory: single-flight, incremental, shared with the engine | A | M1 | L | yes | WS-17 | [04](04-dashboard-state-and-library-consistency.md) | todo |
| WS-19 | Scan snapshot integrity under library changes | A | M1 | M |  | WS-18 | [04](04-dashboard-state-and-library-consistency.md) | todo |
| WS-20 | Permission states and Limited access | A | M1 | M |  | WS-19 | [04](04-dashboard-state-and-library-consistency.md) | todo |
| WS-21 | Library change reconciliation | A | M1 | L |  | WS-11, WS-18, WS-20 | [04](04-dashboard-state-and-library-consistency.md) | todo |
| WS-22 | Analysis reliability and failure reasons | A | M1 | L | yes | WS-07, WS-14 | [05](05-scan-engine-correctness-throughput.md) | todo |
| WS-23 | Incremental and retry scan correctness | A | M1 | L |  | WS-08, WS-16, WS-22 | [05](05-scan-engine-correctness-throughput.md) | todo |
| WS-24 | Scan pipeline throughput and energy hygiene | A | M1 | L | yes | WS-08, WS-23 | [05](05-scan-engine-correctness-throughput.md) | todo |
| WS-25 | Resource-aware scanning: thermal, Low Power and memory pressure | A | M1 | M |  | WS-17, WS-24 | [05](05-scan-engine-correctness-throughput.md) | todo |
| WS-26 | User-initiated vs automatic scans and first-scan auto-start | A | M1 | M |  | WS-17, WS-21 | [06](06-scan-orchestration-and-continuity.md) | todo |
| WS-27 | Videos first, always fresh, never blocking photo review | A | M1 | L |  | WS-10, WS-16, WS-26 | [06](06-scan-orchestration-and-continuity.md) | todo |
| WS-28 | Scan run lifecycle: run lock, backgrounding, interrupted-scan recovery | A | M1 | M | yes | WS-15, WS-24, WS-27 | [06](06-scan-orchestration-and-continuity.md) | todo |
| WS-29 | Long scans on a real device: idle timer and background continuation | A | M1 | M | yes | WS-25, WS-28 | [06](06-scan-orchestration-and-continuity.md) | todo |
| WS-30 | Honest sizing and iCloud locality | A | M1 | L | yes | WS-27 | [07](07-honest-numbers-learning-export.md) | todo |
| WS-31 | Scan outcome single source of truth and completion alerts | A | M1 | L |  | WS-15, WS-22, WS-26, WS-27, WS-28, WS-29, WS-30 | [07](07-honest-numbers-learning-export.md) | todo |
| WS-32 | Honest storage and 'freed' accounting | A | M1 | L |  | WS-11, WS-30, WS-31 | [07](07-honest-numbers-learning-export.md) | todo |
| WS-33 | Preference-learning safety and Release data collection | A | M1 | M |  | WS-13 | [07](07-honest-numbers-learning-export.md) | todo |
| WS-34 | Backup exclusion and feedback I/O | B | M1 | M |  | WS-33 | [07](07-honest-numbers-learning-export.md) | todo |
| WS-35 | Export & Delete completion | A | M1 | L |  | WS-05, WS-10, WS-11, WS-30 | [07](07-honest-numbers-learning-export.md) | todo |
| WS-36 | Central entitlement policy | A | M2 | L |  | WS-11, WS-35 | [08](08-monetization-and-keep-best-yield.md) | todo |
| WS-37 | Analyzer signal correctness (one re-analysis) | A | M2 | L | yes | WS-22, WS-23, WS-24 | [08](08-monetization-and-keep-best-yield.md) | todo |
| WS-38 | Duplicate verification and one-tap identical copies | A | M2 | L |  | WS-13, WS-37 | [08](08-monetization-and-keep-best-yield.md) | todo |
| WS-39 | Similarity threshold calibration (verify-first) | B | M2 | M | yes | WS-22, WS-38 | [08](08-monetization-and-keep-best-yield.md) | todo |
| WS-40 | Burst extras | B | M2 | M |  | WS-13, WS-18, WS-38 | [08](08-monetization-and-keep-best-yield.md) | todo |
| WS-41 | Screenshots and blurry at scale | A | M2 | M |  | WS-12, WS-14, WS-36 | [09](09-bulk-reclaim-and-home.md) | todo |
| WS-42 | Large videos: bulk delete, full coverage, screen recordings, correct slo-mo sizes | A | M2 | L |  | WS-21, WS-27, WS-30, WS-31, WS-36 | [09](09-bulk-reclaim-and-home.md) | todo |
| WS-43 | Compression safety | B | M2 | L | yes | WS-11, WS-30, WS-36, WS-42 | [09](09-bulk-reclaim-and-home.md) | todo |
| WS-44 | Compression UX and outcome | B | M2 | M |  | WS-28, WS-29, WS-32, WS-43 | [09](09-bulk-reclaim-and-home.md) | todo |
| WS-45 | Home leads with bytes | B | M2 | M |  | WS-26, WS-27, WS-31, WS-32, WS-42 | [09](09-bulk-reclaim-and-home.md) | todo |
| WS-46 | ML store as a bounded disposable cache | B | M3 | L |  | WS-20, WS-23, WS-34, WS-37 | [10](10-footprint-and-privacy.md) | todo |
| WS-47 | Persistence health and DEBUG ML export | B | M3 | M |  | WS-46 | [10](10-footprint-and-privacy.md) | todo |
| WS-48 | Privacy, settings and data controls | B | M3 | L |  | WS-27, WS-33, WS-34, WS-46, WS-47 | [10](10-footprint-and-privacy.md) | todo |
| WS-49 | HomeViewModel extraction III: PhotoScanCoordinator | B | M3 | L |  | WS-21, WS-27, WS-28, WS-29 | [11](11-performance-at-scale.md) | todo |
| WS-50 | Render isolation: progress store, 4 Hz throttle, derived-state memos | B | M3 | L |  | WS-16, WS-41, WS-45 | [11](11-performance-at-scale.md) | todo |
| WS-51 | Review image memory and Duck Mode prefetch | B | M3 | M |  | WS-04, WS-12, WS-14 | [11](11-performance-at-scale.md) | todo |
| WS-52 | Thumbnail pipeline: UI lane, size buckets, prefetch, O(1) LRU | B | M3 | M |  | WS-22, WS-51 | [11](11-performance-at-scale.md) | todo |
| WS-53 | Engine scale hardening | B | M3 | L |  | WS-24, WS-40, WS-46 | [11](11-performance-at-scale.md) | todo |
| WS-54 | Checkpoint and cache write cost | B | M3 | L |  | WS-17, WS-47, WS-48, WS-52, WS-53 | [11](11-performance-at-scale.md) | todo |
| WS-55 | Navigation stability, accessibility and Duck Mode chrome | B | M3 | M |  | WS-41, WS-45 | [12](12-accessibility-polish-release.md) | todo |
| WS-56 | Legibility and copy polish: contrast, hit targets, plurals, tokens | B | M3 | L |  | WS-31, WS-36, WS-55 | [12](12-accessibility-polish-release.md) | todo |
| WS-57 | Export resilience | B | M3 | L |  | WS-35 | [12](12-accessibility-polish-release.md) | todo |
| WS-58 | Release engineering, docs, review prompt and App Review notes | B | M3 | M |  | WS-36, WS-47, WS-48, WS-56 | [12](12-accessibility-polish-release.md) | todo |
| WS-59 | Live Photo and RAW/48 MP measurement | C | M4 | M |  | WS-30, WS-45 | [13](13-post-v1-growth.md) | todo |
| WS-60 | Live Photo to still conversion | C | M4 | L | yes | WS-11, WS-36, WS-59 | [13](13-post-v1-growth.md) | todo |
| WS-61 | Cross-date identical copies | C | M4 | M |  | WS-38, WS-53 | [13](13-post-v1-growth.md) | todo |
| WS-62 | Duplicate videos | C | M4 | L |  | WS-42, WS-61 | [13](13-post-v1-growth.md) | todo |
| WS-63 | Similarity sensitivity presets | C | M4 | L |  | WS-08, WS-39 | [13](13-post-v1-growth.md) | todo |
| WS-64 | Retention and growth loop | C | M4 | L |  | WS-32, WS-45, WS-58 | [13](13-post-v1-growth.md) | todo |

---

## 8. Decisions made while writing the chapters

The chapter authors had to make these smaller calls. Each is also marked `DECISION (owner may override)` in its chapter. Sonnet follows them unless the owner says otherwise.

**Chapter 01: Foundation: repo, upload blockers, test seams and stop-ship P0s** ([file](01-foundation-upload-blockers-p0s.md))
- **WS-04:** in an eligible group, the previous keeper is inserted into the delete set, so "Keep this one instead" swaps roles and the delete count does not grow. In a review-only group nothing is auto-marked.
- **WS-05:** they come only from unreleased builds and can't be attributed safely.
- **WS-05:** an asset whose journal append failed is exported but **not** deletion-eligible this run (its record may not survive).
- **WS-05:** these are skipped (never re-copied) but are **not** eligible for Export & Delete. No workstream adds a separate hash backfill. WS-35 (chapter 07) keeps this skip rule and narrows only deletion eligibility through `ExternalExportDeletionSafety.isDeletionSafe` (hash-verified per this workstream, and archival). It also adds an optional "Verify existing exports" pass (WS-35.7) that can upgrade these entries (README…

**Chapter 02: Dev loop: CI, simulator fixtures, engine safety nets and a device baseline** ([file](02-dev-loop-ci-fixtures-baseline.md))
- **WS-07:** the fixture analyzer, seeding and auto-start are compiled only under `DEBUG && targetEnvironment(simulator)`, not merely `DEBUG`.

**Chapter 03: Safe deletion: one honest API, protected automation, trustworthy previews** ([file](03-safe-deletion.md))
- **WS-12:** keep swipes are persisted the moment they are made, because the dialog's own copy promises "discard the marks and keep the photos".
- **WS-13:** under Limited access the provider returns nil and the album rule is skipped. PhotoKit does not reliably expose user albums then, and Keep Best would otherwise become unusable. Device QA 5 verifies this.
- **WS-14:** Delete is disabled while the card is still *loading*, not only when it is unavailable. The spec requires a real preview before a delete. WS-51's prefetch makes the wait invisible.

**Chapter 05: Scan engine: failure reasons, incremental correctness, throughput and thermal adaptation** ([file](05-scan-engine-correctness-throughput.md))
- **WS-22:** transient failures are auto-retried at most three times; Vision failures once per app build; iCloud and missing-resource failures only by an explicit retry.
- **WS-22:** "dominant" means a strict majority. Mixed, transient and legacy sets get the on-device retry first; once reasons are known, iCloud-dominant sets get the download offer.

**Chapter 06: Scan orchestration and continuity: user vs automatic scans, videos first, pause/background/relaunch, long scans** ([file](06-scan-orchestration-and-continuity.md))
- **WS-26:** a user-started refresh that finds nothing new still shows the completion sheet summarizing current results, so the tap always gets feedback.
- **WS-26:** if Home is not the selected tab when a user scan completes, the sheet is dropped (same as today). The Similar tab already shows live results, so a sheet popping up much later when the user returns to Home would surprise them.
- **WS-26:** in the "Continue" branch (`:107`, access already granted), also set the flag when `status` is `.authorized`/`.limited`.
- **WS-27:** a 90 s budget, so photos always start within about 90 s even on an iCloud-heavy library.
- **WS-27:** a transparent engine pause for explicit video refreshes. |
- **WS-29:** onboarding auto-start does not request a continuation, because Apple ties these requests to an explicit user action and the submit happens after the onboarding flow. If 29.0 shows a submit about 1 s after the tap succeeds, the owner may flip this.

**Chapter 07: Honest numbers, outcomes, learning hygiene and export completion** ([file](07-honest-numbers-learning-export.md))
- **WS-30:** Large Videos keeps largest-first order; locality is surfaced by badge, header and an "On this iPhone" filter instead of re-sorting on-device first.`
- **WS-32:** the storage bar never counts unmeasured bytes as iPhone space; they appear only as a "still being measured" note.` Inputs come from `viewModel.dashboardSummary.photoReclaimSizing` and `.largeVideoSizing` (WS-30). Keep the existing bar-and-legend look and tokens; this is Home, not a design-pending screen.
- **WS-32:** a dismissed card stays hidden until a newer deletion is recorded.`
- **WS-35:** .
- **WS-35:** every export (copy-only too) is archival; there is no playable-only export in v1, so any later "Delete Originals" is safe without re-exporting.` Delete `preferredVideoResourceIndex` and its test.

**Chapter 08: Coherent monetization and Keep Best that fires** ([file](08-monetization-and-keep-best-yield.md))
- **WS-36:** how "the lock before effort" works on multi-select surfaces.** Selecting items is never blocked for free users, because the same selection also feeds the free "Add to Export".
- **WS-37:** after an analyzer upgrade, the next user-initiated scan runs as a full re-analysis. Automatic scans stay incremental. No new UI.** v1 is unreleased, so this matters only on development and TestFlight devices.
- **WS-38:** verification tiers.
- **WS-40:** Auto-clean eligibility for burst extras.
- **WS-40:** counting hidden frames.** Hidden burst frames count as processed and analyzed (classified by metadata) and never as unanalyzed. Library totals therefore include them and can exceed the Photos app's visible count.

**Chapter 09: Bulk reclaim: screenshots, videos, compression and a byte-led Home** ([file](09-bulk-reclaim-and-home.md))
- **WS-41:** a swipe "Keep" on a screenshot or blurry photo is written to `UserKeepDecisionStore`, like group keeps. Later category swipe queues skip those IDs. The grid still shows them, and WS-12's "Reset kept photos" restores them.
- **WS-42:** thresholds are decimal bytes, so "100 MB" matches what `ByteCountFormatter` shows on each row. The default moves from 100 MiB to 100,000,000 bytes, so a few more videos qualify.
- **WS-42:** screen recordings are their own category. They are excluded from the Large Videos tile and bytes, so nothing is counted twice, and they always appear in the Files list whatever the threshold.
- **WS-42:** an in-app `confirmationDialog` comes before the iOS prompt, because the system prompt does not show sizes: "Move N videos (≈X) to Recently Deleted?", with the message "≈Y of this is on this iPhone; the rest is stored only in iCloud." and a destructive "Move N to Recently Deleted" button.
- **WS-43:** compression refuses any source delivered as something other than a file-backed `AVURLAsset`. That covers slo-mo, and possibly Cinematic if PhotoKit renders it as a composition.
- **WS-44:** 720p stays H.264 and is labeled as such, rather than building a custom HEVC 720p video composition.

**Chapter 11: Performance at 10k-60k assets** ([file](11-performance-at-scale.md))
- **WS-51:** Duck Mode prefetch uses the same network flag as the card (`true`). Up to three upcoming iCloud-only photos may therefore download before the user reaches them. The override is to prefetch only locally available photos, which makes those cards non-instant.

**Chapter 12: Accessibility, legibility, export resilience and release** ([file](12-accessibility-polish-release.md))
- **WS-55:** in `.snapshot`, the detail stays actionable. Keep Best and Delete Selected commit the snapshot's explicit plan or the user's explicit selection, exactly as before the group changed. This is safe because every commit-time guard still applies:
- **WS-57:** only one resumable export is remembered.
- **WS-57:** a resumed export never deletes automatically, even if the interrupted run was "Export & Delete". It may only *offer* verified deletion (one confirmation plus the iOS prompt).
- **WS-58:** moved, not deleted, so design history stays in the repo but out of the bundle.
- **WS-58:** thresholds count all confirmed receipts in the current app session (reset at launch), so ten one-tap Keep Bests of 5 photos qualify. Errors and declines produce no receipt, so they can never trigger the prompt.

**Chapter 13: Post-v1 growth: Live Photos, RAW, cross-date copies, duplicate videos, presets, retention** ([file](13-post-v1-growth.md))
- **WS-59:** the "RAW & 48 MP" category excludes panoramas and other photos whose short edge is under 4,700 px, unless they are in the RAW album.
- **WS-59:** at most 200 RAW/48 MP photos are stream-measured per idle pass. The rest show WS-30's typed "≈" estimates until later passes measure them.
- **WS-59:** Live Photos, RAW & 48 MP and (WS-62) Duplicate videos are supplementary. They never enter combined "could free" totals, and they are the completion sheet's primary action only when nothing else is actionable.
- **WS-60:** converting credits only the measured motion bytes to "Sent to Recently Deleted" and monthly stats, and does not count converted Live Photos as "items cleaned".`
- **WS-60:** after a declined prompt the conversion run stops, and the pending stills stay on a Home card until the user picks "Keep both" or "Remove the N new stills".
- **WS-61:** an identical copy is found only when the older copy is still resident in the scan, or is among the 10,000 newest photos in the warm cache (WS-46). Older copies are left to Photos' Duplicates album, which the caption mentions.
- **WS-61:** identical-copy candidates require exactly equal pixel dimensions and aHash Hamming ≤ 3.
- **WS-62:** duplicate-video candidates use a 0.02 aspect tolerance and a 1 s minimum duration, and need at least 3 matching informative frames out of 5. Components larger than 12 videos are not shown. Pairs with an iCloud-only member are shown only on an exact measured byte match.
- **WS-63:** Strict = visual distance 0.12 / 0.06 and cluster floors 0.32 / 0.24.`
- **WS-63:** presets are a review-only filter over the scan's Standard results. Pre-WS-63 groups that can't be evaluated stay visible under Strict until the next full scan.
- **WS-63:** when `SimilarityThresholdProfile.standard.revision` increases, Home shows a dismissible "Scan again to update your groups" card, and the next user-initiated scan is a full re-analysis (as for WS-37's `analyzerVersion`). There is no automatic rescan, and automatic scans stay incremental.
- **WS-64:** the monthly reminder is off by default, fires once on the 1st at 10:00 local, and is enabled only from the "This month" card after the primer.
- **WS-64:** the widget has no deep link. Tapping it opens Home.
- **WS-64:** the widget's "to review" count adds duplicate groups, screenshots, blurry photos, large videos and screen recordings, so it mixes groups and items.

---

## 9. Cross-chapter contracts

The chapters were written in parallel, and this section records how their overlaps were resolved. When two chapters disagree, **the earlier workstream's definition wins**, unless a contract below says otherwise. When a later workstream extends a type, it adds to it and never redeclares it.

1. restartPhotoScan: WS-26 (ch06) deletes `restartPhotoScan` and splits it into `refreshPhotoScan()` (incremental, user-initiated) and `rescanEntireLibrary()` (forced full rescan, confirmed gear action, no early return). WS-17 (ch04) must NOT add an early return that turns the gear "Scan Again" into a no-op. WS-17 fixes only the CTA phantom-rescan path, and notes that WS-26 replaces `restartPhotoScan`.
2. ScanPauseGate (introduced in WS-24, ch05) is reason-set based from day one: `pause(_ reason: ScanPauseReason)` / `resume(_ reason: ScanPauseReason)`, open only when the set is empty. Reasons: `.user` (WS-24), `.thermal` (WS-25), `.videoPass` (WS-27), `.background` (WS-28), with later ones added additively. WS-24's sliding-window loop must expose a drain point and an in-flight counter, so WS-27's `pause(reason:quiesceTimeout:) -> PhotoScanPauseAck` can stop top-ups and drain without parking mid-drain.
3. PhotoLibraryInventory (WS-18, ch04) exposes the retained video fetch count and a video-insert signal (e.g. `videoCount` and `onVideosInserted`, from changeDetails.insertedObjects), so WS-27 does not have to patch it.
4. WS-21's single follow-up reconcile fires at the end of every photo run AND at the end of every video pass (the WS-27 pre-pass, an explicit refresh or an insertion rescan), because WS-27 defers automatic scans during any video pass.
5. Own-footprint budget: the M3 target is <= 160 MB after a full scan of a 50k library, measured in WS-54's Device QA. `PhotoEmbeddingCachePolicy.capacity` defaults to 10,000. If the measured footprint exceeds the budget, lower the capacity in steps of 2,500 (minimum 5,000) and record the result. WS-46 and WS-54 acceptance criteria use this budget (not 120 MB).
6. Compression accounting: WS-32's `recordCompressionSavings(originalBytes:outputBytes:)` is canonical. The original enters the Recently Deleted ledger as `.compressionOriginal`, and net savings go to `lifetimeCompressionSavedBytes`. WS-44 calls it only on `.replaced`. There is no `recordCompressionSavings(bytes:)` variant.
7. IdleTimerCoordinator (WS-29, ch06) API: `IdleTimerCoordinator.shared.acquire(reason: String) -> Token`, `release(_ token: Token?)`, test seam `init(apply:)`. WS-44 uses `acquire(reason: "compression")` and releases on every exit.
8. PhotoKitRequestState: WS-10 (ch02) creates `iOSCleanup/Utilities/PhotoKitRequestState.swift` with the generic `PhotoKitRequestState<Value>`. WS-24.5 (ch05) MOVES `PhotoImageRequestState` and `VideoFileSizeRequestState` into that existing file; it does not create the file. WS-14 refers to it as WS-10's file.
9. Test plans (WS-06, ch02): `iOSCleanup.xctestplan` is the default (a plain `xcodebuild … test` runs it) and `Performance.xctestplan` is run with `-testPlan Performance`. There is NO "Unit" plan; fix any reference (e.g. in WS-36) to say "the default test plan (iOSCleanup.xctestplan)".
10. `CleanupOpportunity.Kind` (nested type, WS-31, ch07) is canonical. WS-42 adds `.screenRecordings` additively (with tests). ch09 and ch13 use `CleanupOpportunity.Kind`, never `CleanupOpportunityKind`.
11. CleanupAccessPolicy (WS-36, ch08): the enums in ch08 are canonical (`CleanupAction`, `ManualDeleteSurface`, `BulkSelectSurface`, `PaidFeature`). WS-59 adds `.largePhotos` to ManualDeleteSurface/BulkSelectSurface and WS-62 adds `.duplicateVideos`, additively and with policy tests. WS-41/WS-42 use `.bulkSelect(surface)` and `.manualDelete(surface, count:)` exactly.
12. WS-38 (ch08) screenshot hash index: 4 bands of 16 bits only guarantee a shared exact band for Hamming distance <= 3. Use 7 bands (six 9-bit bands and one 10-bit band) so any pair within Hamming <= 6 shares at least one identical band (pigeonhole). Update the test (e.g. `testScreenshotHashIndexFindsHammingSix` must use the 7-band layout) and the acceptance text.
13. WS-39 vs WS-63: WS-63 (ch13) does NOT build an engine `regroup(thresholds:)` over saved snapshots. After WS-46 only the newest 10k photos have cached analyses, and re-clustering could create destructive plans. A post-release threshold change takes effect on the next user-initiated full re-analysis, mirroring WS-37's analyzerVersion rollout. ch08 WS-39 must not promise `regroup(thresholds:)`.
14. WS-37 (ch08) adds `CachedPhotoAnalysisSnapshot.analyzerVersion` (decodeIfPresent; a mismatch makes the next USER-INITIATED scan a full re-analysis, while automatic scans stay incremental). ch04's snapshot workstreams (WS-15/16/17/19) note that this field arrives later and that their golden tests must tolerate additive fields.
15. WS-53 (ch11) renames PhotoScanUpdate fields (`evaluatedAssetIDs`→`newlyEvaluatedAssetIDs`, `unanalyzedAssetIDs`→`newlyUnanalyzedAssetIDs`, `unanalyzedFailures`→`newlyUnanalyzedFailures`) and removes WS-23's `affectedAssetIDs` and WS-22's `unanalyzedReasonCounts`. WS-53 must explicitly list and update every earlier test that uses the old names (at least `testUnanalyzedAssetsCarryTypedReasons`, `testEveryUpdateCommitsAChronologicalPrefix` and the WS-23 new-photo-joins test). WS-50 moves WS-08's `testProgressSnapshotNeverRegressesAcrossPauseAndResume` to `progressStore.$snapshot`.
16. `HomeViewModelDependencies` (WS-07, ch02) is designed to grow. Later workstreams add fields with production defaults: `feedbackStore` (WS-47), `fileSizeRepository` and `preferenceProfileStore` (WS-48), and `librarySource` (WS-18), `keepDecisions` (WS-12), `reconcileSnapshotDelay` (WS-21) and `videoInventoryCache` (WS-62). ch02 says so and shows the defaults pattern.
17. `iOSCleanupTests/AppConfigurationTests.swift` is created by WS-02 (ch01). WS-48 and WS-58 EXTEND it; they do not create it.
18. WS-62 (ch13) adds `VideoInventoryCache` and must add it to WS-48's `PhotoDuckLocalDataReset` targets and `PhotoDuckStorageFootprint`.
19. WS-52 is cuttable, but WS-54 needs its `LRUCache`. If WS-52 is cut, WS-54 lands WS-52.1 (LRUCache) as its first commit.
20. D-CONTRAST is amended by WS-56: add a dark-chrome rule (`DuckTone.textOnDark`), and include the white-on-danger/success Duck Mode fills. The README decision text will say so.
21. WS-17's pitfall text: WS-54 keeps per-slot state inside the PhotoAnalysisCache actor and relies on WS-17's primary-first mtime read rule. There is no sidecar.
22. WS-12's temporary "Reset Kept Photos" item goes directly below "Scan Again" in the Similar-tab gear menu (`gearshape.fill`, in `PhotoDuckShellView.swift`). WS-48 moves it into Help & Privacy.
23. WS-33 keeps a single `collectsTrainingData` gate (compile flag plus runtime check) that WS-46 reuses. It does not delete `GroupActionFeatureSchema` or the group-outcome export; those become DEBUG-only.
24. WS-27's `LargeVideoScanController` exposes a generation token (or cancellable handle), so WS-48's Clear can fence any scan that started before the clear from writing large-video-results.json afterwards.
25. WS-42 renames `FileScanUpdate.largeFiles`→`retainedVideos`, changes `FileRepresentativeResolver` to `(asset, remeasureEstimates)`, makes `scan()` return `FileScanResult` and deletes `FileScanEngine.minimumFileSizeBytes`. WS-42 owns updating every WS-27/WS-30 code path and test that uses the old names. ch06/ch07 add a one-line forward note where they rely on `largeFiles`.
26. `PhotoImageDeliveryDecision` is introduced by WS-14 (ch03); WS-22 (ch05) EXTENDS it and does not redeclare it. `HomeCTAAction` and its resolver are introduced by WS-31 (ch07); WS-45 (ch09) EXTENDS them with the video pre-pass/video-pass cases (`isVideoPrePassRunning` → CTA disabled "Checking large videos…"; `isVideoPassRunning` → reviewResults).
27. WS-50 changing `FileResultsView`'s init (`actions: LargeVideoActions`, `progress: VideoScanProgressStore`) is acceptable. The "unchanged view API" invariant is about behavior, and additive observation handles are allowed.
28. After WS-32, `CleanupStats`/`CleanupStatsStore` live in `iOSCleanup/Engines/CleanupStats.swift`.
29. Diagnostics JSON keys stay stable (`isFinalizingPhotoScan`, `isFinishingSupportingScans`), fed from `isPhotoRunActive` and `isVideoPassRunning` after WS-28's rename.
31. Export dedupe vs deletion eligibility (WS-05 / WS-35): legacy manifest entries without a hash that are already on the drive are SKIPPED and never re-copied (WS-05), but they are NOT eligible for Export & Delete until verified. WS-35 may offer an explicit "Verify existing exports" pass that hashes the on-drive file against the asset. Only deletion eligibility is gated on `ExternalExportDeletionSafety.isDeletionSafe`; the dedupe/skip set is not.
32. WS-10.5 deletes `VideoFileSizeRequestState` in favour of `PhotoKitRequestState<Int64>`, so WS-24.5 moves only `PhotoImageRequestState` into `PhotoKitRequestState.swift`. Watchdog code (WS-22.4, WS-24.6) goes through WS-06's `watchdogSleep` seam, never `Task.sleep` directly.
33. Every PHAsset fetch passes explicit options. From WS-40, `PhotoFetchLintTests` forbids `options: nil`, so identifier lookups (including DeletionManager's resolver from WS-03/WS-11) use `PhotoLibraryFetch.identifierOptions()`, and DEBUG fetches use `PHFetchOptions()`.
34. Limited Photos access (D-LIMITED-ACCESS): nothing library-derived is persisted under `.limited`, so a cheap large-video pass runs on each launch. That is accepted, because limited selections are small. The results cover only the shared items, and Home says so.
35. Scan pause and lifecycle names (WS-24–WS-29): `ScanPauseReason` {`.user`, `.thermal`, `.videoPass`, `.background`}; engine `drainPoint()`, `inFlightAnalysisCount`, `isInAnalysisLoop`, `pause(reason:quiesceTimeout:) -> PhotoScanPauseAck`; `LargeVideoScanController.passGeneration` / `invalidateAndCancelCurrentPass()`; `BackgroundTaskLease` in `Utilities/BackgroundTaskLease.swift`; `refreshPhotoScan(requestsBackgroundContinuation:)` (internal) and `rescanEntireLibrary()` (private). `PhotoLibraryInventory` (WS-18) defines `videoCount` and `onVideosInserted` and fires them through `applyVideoChange(_:)`, which the WS-21 change consumer calls; WS-27 only subscribes.
36. WS-11 changes WS-03's `PhotoAssetResolver` return type to `ResolvedPhotoAssets` (in `DeletionTypes.swift`, keyed `byID`) and updates WS-03's doubles and tests in the same PR. WS-13 exposes `AssetAlbumMembership.userAlbumCount(for:)` (nil under Limited access). WS-21 publishes confirmed deletions into `applyConfirmedDeletion(assetIDs:)`, which WS-32 extends.
37. Additions accepted from reconciliation: WS-40 adds a change-token reset (a `definitionVersion` key in defaults) and a stricter fetch lint that rejects inline `PHFetchOptions()` outside `PhotoLibraryFetch.swift`. WS-35.7 "Verify existing exports" is a cuttable task. `unverifiedAlreadyExportedAssetIDs` (WS-05) now also covers skipped entries that are not deletion-safe. WS-31 also depends on WS-27, WS-28 and WS-29 because it carries their interim copy.
38. FileScanEngine API after WS-42: `scan(remeasureEstimates:onUpdate:)` (WS-30 introduces it as `revalidateLocality`; `FileScanOptions` is removed), and WS-42 keeps WS-30's 7-day locality recheck. The locality probe is `videoSizeProbe(version:allowNetworkAccess:)`. WS-27's forced refresh is `scanFiles(trigger: .userExplicit)`.

---

## 10. Files in this folder

- [`01-foundation-upload-blockers-p0s.md`](01-foundation-upload-blockers-p0s.md): Foundation: repo, upload blockers, test seams and stop-ship P0s (WS-01–WS-05)
- [`02-dev-loop-ci-fixtures-baseline.md`](02-dev-loop-ci-fixtures-baseline.md): Dev loop: CI, simulator fixtures, engine safety nets and a device baseline (WS-06–WS-10)
- [`03-safe-deletion.md`](03-safe-deletion.md): Safe deletion: one honest API, protected automation, trustworthy previews (WS-11–WS-14)
- [`04-dashboard-state-and-library-consistency.md`](04-dashboard-state-and-library-consistency.md): Dashboard state: HomeViewModel decomposition, launch restore and library consistency (WS-15–WS-21)
- [`05-scan-engine-correctness-throughput.md`](05-scan-engine-correctness-throughput.md): Scan engine: failure reasons, incremental correctness, throughput and thermal adaptation (WS-22–WS-25)
- [`06-scan-orchestration-and-continuity.md`](06-scan-orchestration-and-continuity.md): Scan orchestration and continuity: user vs automatic scans, videos first, pause/background/relaunch, long scans (WS-26–WS-29)
- [`07-honest-numbers-learning-export.md`](07-honest-numbers-learning-export.md): Honest numbers, outcomes, learning hygiene and export completion (WS-30–WS-35)
- [`08-monetization-and-keep-best-yield.md`](08-monetization-and-keep-best-yield.md): Coherent monetization and Keep Best that fires (WS-36–WS-40)
- [`09-bulk-reclaim-and-home.md`](09-bulk-reclaim-and-home.md): Bulk reclaim: screenshots, videos, compression and a byte-led Home (WS-41–WS-45)
- [`10-footprint-and-privacy.md`](10-footprint-and-privacy.md): Own footprint, persistence health and privacy (WS-46–WS-48)
- [`11-performance-at-scale.md`](11-performance-at-scale.md): Performance at 10k-60k assets (WS-49–WS-54)
- [`12-accessibility-polish-release.md`](12-accessibility-polish-release.md): Accessibility, legibility, export resilience and release (WS-55–WS-58)
- [`13-post-v1-growth.md`](13-post-v1-growth.md): Post-v1 growth: Live Photos, RAW, cross-date copies, duplicate videos, presets, retention (WS-59–WS-64)

- `TRACEABILITY.md` maps every review finding to its workstream and chapter, and lists merged duplicates and the deferred finding.
- `BACKLOG.md` is created on demand. It collects out-of-scope issues noticed during implementation.
- `../docs/DEVICE_QA.md` is created by WS-09. It holds the real-device QA checklist and baseline measurements.
