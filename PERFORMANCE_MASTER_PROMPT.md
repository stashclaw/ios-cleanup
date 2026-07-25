# PhotoDuck Performance and Scan-Resume Implementation Prompt
å
Use this prompt from the repository root:

```text
You are working in the PhotoDuck iOS repository.

Repository:
/Users/justinwong/iOSCLEANER/ios-cleanup

Starting branch and reviewed commit:
feat/ml-training-pipeline
8751654 fix: scan honesty, permission timing, deletion guardrails, and review-flow UX

Mission:
Conduct a substantial implementation session making the app materially faster and making scan resume reliable. Budget at least one focused hour when the execution environment permits, but do not treat 60 or 90 minutes as a stopping point. Continue beyond that whenever required to complete the acceptance criteria safely. Do not stop after producing an audit, plan, instrumentation, or one superficial optimization. Inspect the current source, implement the highest-impact safe changes, add tests, run the full test suite, and report measured before/after evidence.

Effort rule:
- Completion criteria, build health, tests, and measured behavior determine when the task is finished, not elapsed time.
- Never idle, sleep, repeat commands without purpose, or delay a response merely to satisfy a time target.
- Do not wrap up early while high-priority requirements remain implementable in the current environment.
- Keep working through implementation, verification, regression fixes, and diff review until the required work is complete or a concrete external blocker is proven.
- If blocked from device-only validation, continue with code, automated tests, instrumentation, simulator verification, and static review rather than stopping.

Source-of-truth rule:
The current code is authoritative. FIXSPEC.md contains useful historical context, but some of its findings and line numbers are stale. Verify every assumption against HEAD before changing code.

Primary user failures:
1. The app is sluggish during scans and while rendering large result sets.
2. Continue/Resume can appear to stall or feel like a fresh scan.
3. Completed analysis should be reused. Opening the app should scan only new, changed, or previously unanalyzed assets.
4. Large-video and thumbnail work must not compete aggressively with the primary photo scan.

Non-negotiable safety rules:
- No destructive action may depend on array ordering, `assets.first`, `dropFirst()`, oldest asset, or incidental sort order.
- Keep the existing explicit `keeperAssetID` and `deleteCandidateIDs` deletion path.
- `visuallySimilar` remains review-only and must never gain automatic delete candidates.
- Preserve precision-first similarity behavior. Do not loosen thresholds merely to find more groups.
- Core ML remains optional and fallback-safe. A missing, incompatible, or slow model must not block scanning or change deletion safety.
- Never classify an unavailable/degraded iCloud thumbnail as a blurry original.
- Do not silently skip assets. Preserve analyzed and unanalyzed accounting.
- Preserve screenshot routing, burst handling, variant guardrails, large-video threshold behavior, contact scanning, export album behavior, and purchase/deletion protections.
- Do not trade correctness for benchmark numbers.
- Do not introduce unbounded tasks, caches, buffers, arrays, or PhotoKit requests.
- Do not perform synchronous PhotoKit, JSON, SQLite, image decode, or filesystem work on the main actor.
- Do not rewrite the review UI. Make only focused rendering/data-flow changes needed for performance.

Required working method:
1. Start by running `git status --short --branch`. Do not overwrite unrelated work.
2. Build a baseline using signposts/counters and existing tests before making broad changes.
3. Implement changes in small cohesive steps.
4. Run targeted tests after each subsystem change.
5. Reserve a meaningful final phase for the full test suite, warning review, and a diff audit; do not postpone verification until the execution budget is nearly exhausted.
6. If a concrete external blocker prevents all requested work from being completed, finish P0 and P1 first, leave the tree buildable, and list exact deferred functions. Time alone is not a blocker. Do not leave half-wired migrations or alternate code paths.
7. Do not claim a speedup without a measurement, signpost interval, operation count, or directly observable reduction in work.

Verified current hot paths to inspect first:

1. Scan update amplification
- `iOSCleanup/Engines/PhotoScanEngine.swift`
- `performScan(...)` yields a full `PhotoScanUpdate` after each asset finishes inside a batch, around the task-group result loop.
- Each update carries full group/category arrays and large identifier sets even when only progress changed.
- `iOSCleanup/Views/HomeViewModel.swift`
- `apply(update:...)` runs on the main actor, unions sets, filters preserved groups/assets, reassigns arrays, and recomputes counts/bytes.
- Goal: publish lightweight progress at a bounded cadence and publish result collections only when their content changes. One update per committed batch is a safe starting point unless profiling justifies another cadence.

2. Full JSON snapshot persistence on the scan path
- `iOSCleanup/Engines/PhotoAnalysisCache.swift`
- `saveSnapshot(_:)` JSON-encodes and atomically replaces the entire cache file.
- `iOSCleanup/Views/HomeViewModel.swift`
- The scan worker awaits `analysisCache.saveSnapshot(checkpoint)` for checkpoints returned by `apply(update:...)`.
- `makeAnalysisSnapshot(...)` sorts identifier sets, maps every group and candidate, and includes all known library metadata.
- Goal: preserve durable resume semantics without blocking each scan batch on a full-library JSON rewrite.

3. SQLite calls are transactional but too frequent
- `iOSCleanup/Engines/PhotoScanEngine.swift`
- Every analysis batch awaits both `persistFeatureRecords` and `persistPairSimilarities`.
- Pair cache lookup currently occurs per analyzed asset.
- `iOSCleanup/Engines/PhotoMLBridge.swift`
- Persistence calls open/write immediately.
- `iOSCleanup/Engines/PhotoMLStore.swift`
- Bulk functions use transactions, but inner upserts prepare/finalize statements repeatedly.
- Goal: buffer bounded writes, reuse prepared statements within a transaction, and flush at explicit durability boundaries.

4. Repeated Vision and PhotoKit work
- `PhotoScanEngine.analyzeAsset(...)` requests a 224 image, may retry high quality, may request a 1024 confirmation image, computes keeper signals, generates a Vision feature print, and computes a perceptual hash.
- The feature store does not currently include a clear asset modification date plus analyzer-version cache contract.
- Pair-cache reads exist and must be retained, but warm resume still may decode/reanalyze context assets.
- Goal: reuse per-asset analysis only when keyed by asset ID, modification date, pinned Vision/embedding version, and analyzer version. Never reuse stale analysis after edits.

5. Broad observable state and render-time aggregation
- `iOSCleanup/Views/HomeViewModel.swift` is a large `ObservableObject` with many independent `@Published` properties.
- `iOSCleanup/Views/HomeView.swift` filters groups and reduces byte totals in view evaluation.
- `iOSCleanup/Views/Photos/PhotoResultsView.swift` repeatedly builds visible/filtered arrays, aggregate sets, and `Array(filteredGroups.enumerated())`.
- `iOSCleanup/Views/Files/FileResultsView.swift` can render over a thousand rows, each starting its own thumbnail task.
- Goal: reduce publication fan-out and repeated O(n) work without redesigning the UI.

6. Duplicate, unbounded, and network-enabled thumbnail work
- `iOSCleanup/Utilities/SharedHelpers.swift`
- `PHAsset.loadImage(...)` is cancellation-safe, but callers do not share/deduplicate requests or cache decoded thumbnails.
- `PhotoResultsView`, `FileResultsView`, `PhotoDuckShellView`, `PhotoGroupDetailView`, `SwipeModeView`, and Home category cards each load independently.
- `FileResultsView.FileRow` enables network access for every large-video thumbnail.
- Goal: add one shared, bounded thumbnail repository with request coalescing, cancellation, and memory-pressure eviction. Keep review/detail images at the required quality; cache keys must include asset ID, modification date, target size, content mode, and quality intent.

7. Supporting scans compete with the primary scan
- `HomeViewModel.apply(update:...)` starts `scanSupportingCategoriesIfNeeded()` on the first photo-scan update.
- That method starts large-file scanning and then contacts scanning.
- `FileScanEngine` measures videos in batches of eight, publishes and resorts the full result after every batch.
- Goal: assign explicit resource priority. Do not let large-video URL/size requests and hundreds of thumbnails starve the active photo scan or foreground review.

8. File-size cache is process-only
- `iOSCleanup/Utilities/PHAsset+FileSize.swift`
- `AssetFileSizeCache` is an in-memory dictionary without an eviction limit or durable reuse.
- `FileScanEngine` has to remeasure the video library after relaunch.
- Goal: persist authoritative/estimated size plus provenance using asset ID and modification date, and keep the in-memory layer bounded.

9. Missing performance observability
- There is no current `OSSignposter`/`os_signpost` coverage for scan phases, cache restore, snapshot encoding, SQLite flushing, grouping, image requests, or result publication.
- Goal: add low-overhead DEBUG signposts and counters so future optimization is evidence-based.

P0: Resume correctness and immediate progress

Implement and verify all of the following:

- Resume restores the saved checkpoint and existing partial results before starting new work.
- Resume never resets displayed processed count, target count, findings, screenshots, blurry items, or large-video results to zero.
- The resume target is exactly:
  - new assets,
  - changed assets,
  - assets in the unfinished checkpoint,
  - previously unanalyzed assets selected for retry,
  - and only the bounded context assets required to compare those assets safely.
- Already completed unchanged assets are not sent through `analyzeAsset(...)` again.
- Separate attempted, analyzed, unanalyzed, and durably committed progress.
- The UI must say what it is doing if the first resumed batch is waiting on local/iCloud data. It must not look frozen.
- Pause, cancellation, backgrounding, and process termination must leave a checkpoint that can be resumed.
- A completed snapshot must never be written before the committed target is complete.
- A PhotoKit change notification during a scan must not finalize, reset, or restart that scan.

Add DEBUG diagnostics for:
- restored checkpoint count,
- required IDs count,
- context IDs count,
- cache-hit count,
- cache-miss count,
- reanalyzed asset count,
- first resumed progress latency,
- committed checkpoint generation.

P1: Remove full snapshot serialization from the tight loop

Introduce a dedicated persistence coordinator or equivalent single authoritative path.

Required behavior:
- Coalesce checkpoint writes. Never launch overlapping JSON encodes or atomic replacements.
- Maintain generation ordering so an older write cannot overwrite a newer checkpoint.
- Never mark asset IDs durably processed unless the same durable generation contains the corresponding group/category state needed on restore.
- A scan may continue while a checkpoint is encoding, but background/pause/termination/completion must request and await a forced flush.
- Keep only one pending newest snapshot; discard superseded pending snapshots.
- Use a conservative periodic full-checkpoint interval as a tuning constant, initially 15-30 seconds, plus forced lifecycle flushes.
- Completed result persistence can remain a full snapshot, but it must execute off the main actor.
- Consider separating compact progress/checkpoint metadata from the completed result snapshot if that reduces work without weakening the commit invariant.
- Keep migration compatible with the current schema-7 cache. Existing users must not lose safe completed results.
- Add a cache-size guard and a recovery path for corrupt/partial files.

Acceptance:
- Normal scan batches do not await a full JSON encode/write.
- No more than one full checkpoint encode is active.
- Relaunch resumes from the latest fully committed generation.
- Killing during an in-flight write falls back to the prior valid generation.

P2: Reduce scan work and database overhead

Implement the safest high-impact subset supported by measurements:

- Stop emitting full result snapshots for every asset completion.
- Use a bounded progress publication rate, initially no more than 4 UI updates/second and preferably one committed update per analysis batch.
- Do not reassign `photoGroups`, `screenshotAssets`, `blurryAssets`, or `largeFiles` when their IDs/content have not changed.
- Buffer feature and pair records in a bounded actor/coordinator.
- Suggested tuning defaults:
  - feature flush count: 64-128 records,
  - pair flush count: 256-512 records,
  - maximum flush latency: 1-2 seconds,
  - always flush on pause/background/cancel/completion.
- Reuse prepared SQLite statements across each transaction.
- Batch pair-cache reads where practical; do not execute one actor/SQLite round trip for every individual asset if the batch can resolve the keys together.
- Preserve `PhotoEmbeddingContract`, pinned Vision revision, pair-cache validation, retention, and fallback behavior.
- Add `modification_date`, `analyzer_version`, and analysis availability/provenance only through a tested schema migration if per-asset warm-cache reuse is implemented.
- A cached analysis is valid only when asset ID, modification date, image dimensions/subtype facts, embedding version, and analyzer version match.
- If Vision observations cannot be reconstructed safely from stored data, use a tested value-type distance implementation over validated embedding bytes or leave that subtask deferred. Never use private APIs or unchecked blob casts.
- Keep all tuning values named in a constants type.

P3: Keep grouping incremental and bounded

- Preserve the existing bounded candidate selector and complete-link anti-chaining behavior.
- Do not reintroduce full-library O(n²) comparisons.
- Profile `makeGroups(...)`, sorting, graph formation, cluster classification, and keeper ranking separately.
- Existing member-ID group memoization should remain the one authoritative keeper-ranking path.
- Avoid rebuilding unchanged clusters.
- If cluster refresh is still expensive, maintain dirty cluster/component IDs or increase refresh spacing using a named adaptive schedule.
- The final update must always classify all committed evidence.
- Do not reduce result quality by dropping burst edges, screenshot duplicate evidence, or safe context assets.

Acceptance:
- Candidate comparisons remain capped by existing policy constants.
- A 50k-asset library does not allocate pair structures proportional to n squared.
- Unchanged groups keep stable IDs and are not reranked or republished.

P4: Isolate observable state and remove render churn

Prefer a minimal-risk refactor:
- Split rapidly changing progress from large result collections, either through focused child observable stores or another mechanism compatible with the deployment target.
- A progress tick should not invalidate every result card.
- Publish one value-type progress snapshot atomically instead of mutating many counters independently when practical.
- Precompute dashboard summaries when collections change:
  - duplicate count,
  - visually-similar count,
  - reviewable count,
  - delete-candidate count,
  - reclaimable bytes,
  - large-file bytes.
- Avoid `Set(flatMap(...))`, repeated filters/reduces, and `Array(enumerated())` in hot SwiftUI body evaluation.
- Preserve stable identity. Do not replace model IDs while merely refreshing metadata.
- Use lazy containers and bounded/paginated rendering for very large lists.
- Do not copy input arrays into stale `@State`.

Target files:
- `iOSCleanup/Views/HomeViewModel.swift`
- `iOSCleanup/Views/HomeView.swift`
- `iOSCleanup/Views/Photos/PhotoResultsView.swift`
- `iOSCleanup/Views/Files/FileResultsView.swift`
- `iOSCleanup/Views/PhotoDuckShellView.swift`

P5: Shared image pipeline

Add one authoritative thumbnail/image repository, not another one-off helper.

Required behavior:
- Coalesce identical in-flight PhotoKit requests.
- Cancel requests when all consumers disappear.
- Bound decoded-image memory using `NSCache` total cost or equivalent.
- Cost images by decoded pixel bytes, not compressed file bytes.
- Observe memory pressure and evict aggressively.
- Distinguish thumbnail, review, and fullscreen quality intents.
- Use display-scale-aware target sizes.
- Never return a small thumbnail as the review image merely because it is cached.
- Foreground review images take priority over scan thumbnails.
- Prefetch only a small current/next window in swipe/detail flows.
- Default large-video list thumbnails to local-only; show a cloud placeholder/action instead of downloading hundreds automatically.
- Keep request continuation and cancellation exactly-once behavior.

Add tests around:
- key equality,
- request coalescing,
- cancellation,
- quality separation,
- bounded eviction where testable,
- no low-resolution cache hit for a higher-quality request.

P6: Supporting scans and persistent file metadata

- Do not automatically run expensive video measurement at equal priority with an active deep scan.
- Use a small resource coordinator, priority state, or lifecycle policy:
  - foreground review images first,
  - primary photo scan second,
  - large-video measurement third,
  - contacts last unless the user explicitly opens Contacts.
- Explicit user navigation to Large Videos may promote that work.
- Persist large-video size results keyed by local identifier and modification date.
- Store whether a size is measured or estimated.
- Invalidate changed/deleted assets through the existing Photo Library observer.
- Bound the in-memory size cache.
- Publish large-file deltas or at a throttled cadence; do not resort/reassign the whole array after every eight measurements if unchanged.
- Keep the product rule: Large Videos means videos at or above 100 MiB.

P7: Instrumentation and runtime warnings

Add low-overhead DEBUG instrumentation with `OSSignposter` or equivalent around:
- library fetch and metadata diff,
- checkpoint restore and rehydration,
- incremental target/context selection,
- PhotoKit image wait,
- Vision feature extraction,
- candidate selection and distance calculation,
- pair-cache read/write,
- group graph/classification,
- keeper ranking,
- snapshot construction/encoding/write,
- main-actor apply/publication,
- large-video size measurement,
- thumbnail cache hit/miss/request.

Record counts with each interval where possible. Avoid logging asset IDs or private photo metadata in release builds.

Resolve new Swift concurrency warnings rather than hiding them with blanket `@unchecked Sendable`. Keep any existing `@unchecked Sendable` only where the synchronization invariant is documented and tested.

Testing requirements

Preserve and run all existing safety tests. Add focused tests for:

1. Resume from a partial checkpoint retains previous groups and begins after committed work.
2. Resume does not reanalyze unchanged completed assets.
3. New/changed/unanalyzed asset selection includes required bounded context but not the whole library.
4. Progress never regresses across pause/resume.
5. A stale write generation cannot replace a newer snapshot.
6. Coalesced checkpoint writes retain the newest generation.
7. Cancellation/background forces a durable checkpoint flush.
8. Completed state cannot persist when committed count is below target.
9. Scan update count is bounded relative to batch count, not asset count.
10. Feature/pair write buffers flush by count, time, and lifecycle.
11. Warm analysis cache invalidates on modification date or analyzer/embedding version change.
12. Existing pair-cache validation still rejects wrong versions or malformed distances.
13. Large-video cache invalidates when the asset changes and keeps the 100 MiB boundary.
14. Thumbnail requests coalesce and do not cross quality classes.
15. `visuallySimilar` exposes no delete candidates and cannot pass auto-clean eligibility.
16. Explicit keeper/delete IDs remain authoritative after caching, resume, UI filtering, and deletion.
17. Chaining/split, screenshot-vs-camera, burst, edited/original, and iCloud blur guardrail tests still pass.
18. Performance regression tests for pure functions:
   - candidate selection remains bounded,
   - update/coalescing counts remain bounded,
   - snapshot coordinator never has multiple active encodes.

Verification commands:

1. Inspect available schemes:
`xcodebuild -project iOSCleanup.xcodeproj -list`

2. Run the full suite on an available simulator, selecting an installed device/runtime:
`xcodebuild test -project iOSCleanup.xcodeproj -scheme iOSCleanup -destination 'platform=iOS Simulator,name=<installed device>'`

3. Also run targeted tests while iterating:
- `PhotoScanEngineTests`
- `PhotoMLStoreTests`
- `SimilarityPolicyTests`
- `FileScanEngineTests`

4. Build with strict warning review. Report all remaining warnings and distinguish pre-existing from introduced.

Physical-device verification is required for final confidence:
- Use a library with tens of thousands of assets and Optimize iPhone Storage enabled if available.
- Start a deep scan, let it make meaningful progress, pause/background/kill, relaunch, and Continue.
- Record:
  - restored processed/target count,
  - time to restored UI,
  - time to first new attempted progress,
  - time to first durable committed progress,
  - cache hits/misses,
  - assets actually reanalyzed,
  - checkpoint encode/write durations,
  - main-thread hitch evidence,
  - memory high-water mark,
  - scan rate before and after.
- Open Similar and Large Videos during a scan and verify scrolling remains responsive.
- Verify a review image is full-quality before fullscreen and does not display a cached low-resolution thumbnail.
- Verify network-disabled assets show honest unavailable/cloud state rather than false blur or a permanent spinner.

Quantitative acceptance targets

Treat these as safe starter targets, not reasons to falsify behavior:
- Resume count never returns to zero or regresses.
- Restored cached UI appears before new analysis starts.
- No full snapshot write occurs per eight-asset batch.
- No more than one checkpoint encode/write is active.
- Main-actor progress publication is capped at 4 Hz.
- Result collection publication occurs only on content change.
- Thumbnail and file-size caches are bounded.
- Candidate comparison count remains capped by policy constants.
- Scrolling does not launch unbounded network PhotoKit requests.
- No new main-thread operation over 100 ms attributable to snapshot encoding, SQLite, PhotoKit metadata, or image decode.
- Tests pass with zero new concurrency/runtime warnings.

Priority order if time is constrained

1. P0 resume correctness plus diagnostics.
2. P1 checkpoint coalescing/off-main persistence.
3. P2 update amplification and batched database writes.
4. P4 observable/render churn.
5. P5 shared thumbnail pipeline.
6. P6 supporting scan arbitration and persistent file-size cache.
7. Remaining warm-cache/schema and deeper grouping optimization.

Do not make these tempting but unsafe changes

- Do not simply increase analysis concurrency above eight without profiling memory, thermal state, and PhotoKit contention.
- Do not remove high-quality blur confirmation.
- Do not skip failed/iCloud assets while counting them as analyzed.
- Do not make checkpoint writes fire-and-forget without generation ordering and lifecycle flushes.
- Do not use UserDefaults for large identifier arrays or image/feature data.
- Do not cache by asset ID alone.
- Do not weaken similarity thresholds to make the scan appear more productive.
- Do not create a second keeper-ranking implementation.
- Do not let UI sort order define deletion.
- Do not delete old cache/schema support until migration tests pass.
- Do not add a global singleton cache without a cost limit and invalidation contract.
- Do not finish with only comments, TODOs, signposts, or a plan.

Required final report

Return:

A. Baseline findings
- Measured top bottlenecks and operation counts.

B. Files changed
- File-by-file summary and why each change is safe.

C. Resume behavior
- Exact checkpoint/target/context/cache logic after the change.

D. Scaling changes
- Work removed, coalesced, cached, bounded, or moved off-main.

E. Tests
- New tests, full command used, pass/fail totals, and any skipped tests.

F. Before/after evidence
- Signpost durations, update/write counts, scan rate, memory, and UI responsiveness.

G. Safety confirmation
- Explicitly confirm array order is not used for deletion, visuallySimilar remains review-only, and Core ML remains optional.

H. Deferred work
- Exact file/function references, reason deferred, and the next safest implementation step.

Before ending:
- Review `git diff --check`.
- Review `git status --short`.
- Search the diff for `assets.first`, `dropFirst`, `deleteCandidateIDs`, `visuallySimilar`, `Task.detached`, `@unchecked Sendable`, `requestImage`, and snapshot writes.
- Confirm no unrelated user changes were reverted.
```

## Expected Session Shape

The agent should spend the session implementing, not waiting. These are minimum phases rather than a maximum duration:

- Opening phase: baseline, signposts, targeted tests, and confirmed bottleneck ranking.
- Core phase: P0/P1 plus the highest-impact P2 changes.
- Expansion phase: targeted UI/image, database, caching, or supporting-scan improvements after P0/P1 are stable.
- Verification phase: targeted and full tests, warning cleanup, diff audit, and measured reporting.
- Iteration phase: fix regressions or missed acceptance criteria discovered during verification, then rerun the affected checks.

The agent should continue for multiple hours if that is what a safe, complete implementation requires. It must not stop merely because the initial hour has passed.

If physical-device access is unavailable, the agent must still implement automated coverage and instrumentation, clearly mark device verification as unperformed, and provide exact steps rather than inventing measurements.
