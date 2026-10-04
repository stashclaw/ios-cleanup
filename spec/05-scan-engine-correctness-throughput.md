# Chapter 05 — Scan engine: failure reasons, incremental correctness, throughput and thermal adaptation

> **Milestone(s):** M1 · **Workstreams:** WS-22 – WS-25 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

All four workstreams change `PhotoScanEngine` and its helpers, so they land strictly in order: WS-22 → WS-23 → WS-24 → WS-25. When the chapter is done:

- Every photo PhotoDuck could not analyze carries a typed reason. Vision failures retry once on the CPU. "Download and Rescan" appears only when iCloud-only photos are the main cause.
- New and retried photos are compared with their already-analyzed neighbors, groups never overlap, and a large iCloud retry pass keeps a bounded amount of embedding memory.
- The pipeline keeps eight analyses in flight all the time instead of waiting for the slowest photo in each batch of eight. A paused scan stops waking the CPU.
- Long scans slow down when the iPhone is warm or in Low Power Mode, pause when it is critically hot, and give up memory when iOS warns.

The key risk is silently changing classification. Every task below keeps full-scan candidate selection, pair classification and keeper choice identical. WS-08's end-to-end tests and a reference-equivalence test are the regression net. Performance work never changes classification (README §5).

---

## WS-22 — Analysis reliability and failure reasons

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-07, WS-14 | yes | `ws/22-analysis-failure-reasons` |

**Primary files:** `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Utilities/SharedHelpers.swift`, `iOSCleanup/Engines/PhotoAnalysisCache.swift`, `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/HomeView.swift` (or the file WS-10 moved `iCloudAnalysisBanner` into), `iOSCleanup/Views/Home/AnalysisCheckpointState.swift` (if WS-16 landed), `iOSCleanup/Engines/PhotoAnalysisFailure.swift` *new*, `iOSCleanup/Engines/PhotoFeaturePrintGenerator.swift` *new*, `iOSCleanup/Engines/PhotoAssetAnalysisPipeline.swift` *new*, `iOSCleanup/Utilities/PhotoImageDeliveryDecision.swift` (created by WS-14; extended here), `iOSCleanup/Utilities/PHAsset+ImageLoadOutcome.swift` *new*, `iOSCleanup/Utilities/AsyncSemaphore.swift` *new*, `iOSCleanup/Views/Home/UnanalyzedPhotosBannerModel.swift` *new*
**Findings covered:** SCAN-03 (P2, partially; merged: FSA-03), SCAN-14 (P2, partially)
**Decisions applied:**
- D-MIN-OS: the deployment target is iOS 17.0 after WS-06, so the CPU retry calls `setComputeDevice(_:for:)` directly. Do not use the deprecated `usesCPUOnly`. If the owner overrode D-MIN-OS and the target is still below 17, wrap the CPU selection in `if #available(iOS 17.0, *)` and treat the retry as unavailable on older systems.
- D-REANALYSIS: do **not** bump `PhotoMLBridge.analyzerVersion` or `PhotoEmbeddingContract.embeddingVersion`. Cached analyses stay valid.

### Goal
Every unanalyzed photo has a persisted, typed reason. A device Vision failure is retried once on the CPU before the photo is written off. Capacity limits never produce an "unanalyzed" photo. Automatic rescans only retry photos that can plausibly succeed now, and an explicit retry button can always force every photo. Home offers "Download and Rescan" only when iCloud-only photos are the majority of the unanalyzed set. In every other case it offers an on-device "Try Again".

### Current behavior (verified)
- `iOSCleanup/Engines/PhotoMLBridge.swift:44-48`: `makePinnedFeaturePrintRequest()` sets only `request.revision = pinnedFeaturePrintRevision`. WS-07 adds a simulator-only CPU assignment here. There is no device fallback.
- `iOSCleanup/Engines/PhotoScanEngine.swift:82-94`: `PhotoScanAssetAnalysis` holds observation, embedding, perceptualHash and keeperSignals, and has no reason field. `.unavailable` is all-nil.
- `PhotoScanEngine.swift:1009-1090` (`analyzeAsset`):
  - It tries `.analysisFast`, then falls back to `.analysis` (1020-1032).
  - A nil image returns `.unavailable` (1033-1035).
  - The Vision `catch` returns `embedding: nil` but still computes `makePerceptualHash` and the keeper signals (1080-1087).
- `PhotoScanEngine.swift:665-673`: a photo counts as unanalyzed only because `analysis.featureValue.embedding == nil`. No reason is recorded.
- `PhotoScanEngine.swift:181-234`: the Vision executor has a 4-wide `OperationQueue` and `maximumScheduledCount = 8`. `guard wasScheduled else { return .unavailable }` (204) turns capacity into an unanalyzed photo, and cancellation also resolves `.unavailable` (209).
- `PhotoScanEngine.swift:256-261`: the coordinator returns `.unavailable` when `activeOperationCount >= max`. Today this is unreachable. Every path releases the slot before resolving (277-279, 285-288), and the lock-step loop only starts a new batch after the previous one resolved.
- `PhotoScanEngine.swift:596-605`: the watchdog is 15 s without network and 45 s with it.
- `iOSCleanup/Utilities/SharedHelpers.swift:325-332`:
  - `.analysisFast` uses `.fastFormat` with `acceptsDegradedResult = false` and a 4 s timeout.
  - `.analysis` uses `.highQualityFormat` with 6 s (15 s with network).
  - Worst case without network is 4 + 6 + 6 s (the 1,024 px blur confirmation at `PhotoScanEngine.swift:1043-1049`) = 16 s, which exceeds the 15 s watchdog. A watchdog timeout also throws away the hash and keeper signals.
- `SharedHelpers.swift:586-600`: in the result handler, a degraded image with no error matches neither branch, so the request waits for its full timeout. Whether `.fastFormat` marks local derivatives as degraded is device behavior (see WS-22.0).
- `SharedHelpers.swift:26-59` and `:599-609`: UI and analysis share one `RequestExecutor` (16 scheduled launches). When it is full, `requestAsynchronously` returns false and `loadImage` resolves nil at once. `SharedHelpers.swift:61-97`: `CancellationExecutor` drops cancels beyond 8 (79-84). That belongs to WS-52.
- `iOSCleanup/Engines/PhotoAnalysisCache.swift:37-42, 260-263`: the snapshot stores only `unanalyzedAssetIdentifiers` (`decodeIfPresent`). Three sites construct snapshots:
  - `repairingPrematureCompletion` (95-130)
  - `withPersistenceGeneration` (855-883)
  - `HomeViewModel.makeAnalysisSnapshot` (~2048), or `AnalysisSnapshotBuilder` after WS-16
- `PhotoAnalysisCache.swift:267-330`: `PhotoScanResumePlanner.requiredAssetIDs` unions `previouslyUnanalyzedIDs ∩ current` into both the resume branch (312) and the completed branch (328). Commit 8e7e5c3 added this. `HomeViewModel.swift:1921-1946` starts an automatic incremental scan whenever new or modified photos exist, so every such scan re-attempts every earlier failure.
- `HomeViewModel.swift:1348-1365`: `retryIncludingICloudPhotos()` is the only retry, and it always uses `allowNetworkAccess: true`.
- `HomeView.swift:104-106, 528-548, 150-160`: whenever `unanalyzedPhotoCount > 0` after completion, the banner says "…downloads originals from iCloud if needed" and routes to the "Analyze iCloud photos?" dialog with "Download and Rescan".
- `HomeViewModel.swift:1266-1285`: the `catch let error as ScanError` switch is exhaustive over `.permissionDenied` and `.photoLibraryTemporarilyUnavailable`.
- `iOSCleanup/Engines/PhotoMLStore.swift:678-704`: failed analyses (nil embedding) are written to `photo_asset_analysis` but never returned as cache hits, because the join requires `features.embedding IS NOT NULL`. They are re-analyzed whenever they are targeted.
- `iOSCleanupTests/PhotoScanEngineTests.swift:36-57`: the only Vision test skips on simulator error 9 (`VNErrorCode.internalError`, "Could not create inference context", runtime RT-1).

### Implementation plan

**WS-22.0 — Verify-first: read the WS-09 baseline**
- **Why:** SCAN-14's "7 h scans" estimate assumes `.fastFormat` flags local thumbnails as degraded, so each photo waits the full 4 s. That is unverified.
- **Change:**
  - Open the WS-09 run in `docs/qa-runs/` and record in the PR: whether fastFormat returned degraded images for local assets, per-asset analysis time (p50/p99), and the unanalyzed count on a normal device.
  - If the run lacks the fastFormat observation, add a DEBUG-only counter `PhotoAnalysisDiagnostics.fastDegradedCount`, incremented in WS-22.2 when a degraded fastFormat image is accepted, and add a device QA step.
  - Implement WS-22.1–22.7 regardless. The decision function and the capacity waits are correct whatever the device does.

**WS-22.1 — Failure taxonomy and the analysis result**
- **Why:** unanalyzed photos carry no reason, so the UI cannot tell iCloud from Vision failures, and the planner re-queues everything.
- **Change:**
  - New file `iOSCleanup/Engines/PhotoAnalysisFailure.swift` (sketch below).
  - In `PhotoScanEngine.swift`, add `let failure: PhotoAnalysisFailureKind?` to `PhotoScanAssetAnalysis`, plus an explicit `init(observation:embedding:perceptualHash:keeperSignals:failure: PhotoAnalysisFailureKind? = nil)` so existing call sites and tests compile unchanged.
  - Add `static func failed(_ kind: PhotoAnalysisFailureKind, perceptualHash: UInt64? = nil, keeperSignals: KeeperSignals? = nil) -> PhotoScanAssetAnalysis`. `.unavailable` keeps `failure: .unknown`.
  - Engine rule: `effectiveFailure = analysis.embedding == nil ? (analysis.failure ?? .unknown) : nil`. A non-nil embedding always means analyzed, even if an injected analyzer set a failure.

```swift
enum PhotoAnalysisFailureKind: String, Codable, Sendable, CaseIterable {
    case notLocal              // only in iCloud and network access was off
    case downloadFailed        // network allowed, PhotoKit could not fetch it
    case noResource            // PhotoKit has no renderable resource on device
    case timedOut              // an image stage or the per-asset watchdog timed out
    case visionFailed          // Vision threw on the default device and again on CPU
    case incompatibleEmbedding // observation element/byte count mismatch
    case capacity              // must not occur after this WS; transient if it does
    case cancelled             // run cancelled while in flight
    case unknown               // legacy record without a reason, or injected `.unavailable`

    init(from decoder: Decoder) throws {   // a newer build's reason must never fail snapshot decode
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
    var isICloud: Bool { self == .notLocal || self == .downloadFailed }
    var isDeviceFailure: Bool { self == .visionFailed || self == .incompatibleEmbedding || self == .noResource }
}

struct PhotoAnalysisFailureEntry: Codable, Equatable, Sendable {
    let assetID: String
    let kind: PhotoAnalysisFailureKind
    let attemptCount: Int   // number of runs in which this asset was attempted and failed
    let appBuild: String    // CFBundleVersion of the run that recorded `kind`
}
```
- **Edge cases:** do not add `Hashable` synthesis that depends on raw values that may change. Keep raw values stable, because they are persisted.

**WS-22.2 — Image delivery decision, outcome loading and the analysis lane**
- **Why:** three problems:
  - A degraded single-shot result waits for the full timeout.
  - Capacity rejections look like "unanalyzed".
  - Load failures carry no reason.
- **Change:**
  1. Extend WS-14's `iOSCleanup/Utilities/PhotoImageDeliveryDecision.swift` (README contract 26). Do **not** redeclare `PhotoImageDeliveryDecision`, and leave WS-14's `decide(imagePresent:isDegraded:hasError:acceptsDegraded:fallsBackToDegraded:)`, `PhotoImageDeliveryAction` and `PhotoImageLoadResult` unchanged. Add to the same file:
     - `enum PhotoImageLoadFailure: Equatable, Sendable { case notLocal, downloadFailed, noResource, timedOut, cancelled, capacity }` with `var analysisFailureKind: PhotoAnalysisFailureKind` (a one-to-one mapping).
     - `enum PhotoImageLoadOutcome: @unchecked Sendable { case image(PhotoImageLoadResult); case failed(PhotoImageLoadFailure); var result: PhotoImageLoadResult?; var image: UIImage? }`. It carries WS-14's `isDegraded`, so the repository's "never cache a degraded result" rule keeps working.
     - The analysis-lane rule and the failure classifier below, as an `extension PhotoImageDeliveryDecision`.
  2. New file `iOSCleanup/Utilities/AsyncSemaphore.swift`: a FIFO, cancellation-aware actor (sketch below). WS-52 builds its UI lane on its own `PhotoImageLaunchLane` and may re-express this analysis lane through it; it does not reuse `AsyncSemaphore` for the UI lane.
  3. New file `iOSCleanup/Utilities/PHAsset+ImageLoadOutcome.swift`:
     - Move the body of WS-14's `PHAsset.loadImageResult(…fallsBackToDegraded:)` (the old `loadImage` body, `SharedHelpers.swift:545-617` at baseline) here as `func loadImageOutcome(targetSize:deliveryMode:allowNetwork:contentMode:acceptsDegradedResult:fallsBackToDegraded:timeout:lane: PhotoImageRequestLane) async -> PhotoImageLoadOutcome`.
     - `enum PhotoImageRequestLane { case ui, analysis }`.
     - `.ui` lane: the handler keeps WS-14's `decide(imagePresent:…)` and its four actions exactly. When an action resolves without an image, record `PhotoImageDeliveryDecision.failure(domain:code:isInCloud:allowsNetworkAccess:)` as the failure.
     - `.analysis` lane (single-shot): the handler calls `decideAnalysis(_:)`: `.accept` → `state.resolve(image)`, `.reject(f)` → `state.resolve(nil, failure: f)`. It never waits.
     - `PHImageResultIsInCloudKey`, `PHImageCancelledKey`, `PHImageResultIsDegradedKey` and `PHImageErrorKey` (as `NSError`: domain and code) feed `AnalysisInput`. The minimum side is `Int(min(image.size.width, image.size.height) * image.scale)`.
     - Keep WS-14's `loadImageResult(…)` in `SharedHelpers.swift` as a wrapper, `await loadImageOutcome(..., lane: .ui).result`, and `loadImage(...)` as the one-line wrapper WS-14 left. UI call sites do not change.
  4. `PhotoImageRequestState` (in `SharedHelpers.swift` at this point; grep `final class PhotoImageRequestState`. WS-24.5 moves it into WS-10's `PhotoKitRequestState.swift`). Extend WS-14's API and keep its parameters and defaults:
     - Add `private var failure: PhotoImageLoadFailure?`, a trailing `failure: PhotoImageLoadFailure? = nil` parameter on WS-14's `resolve(_:isDegraded:)` (the first resolve wins, as today), and `var recordedFailure: PhotoImageLoadFailure?`.
     - Add `reason: PhotoImageLoadFailure = .cancelled` to WS-14's `cancel(cancelRequest:fallbackToRemembered:)`. The timeout path passes `.timedOut`; a timeout that resolves with WS-14's remembered degraded image records no failure. The existing test `testImageRequestTimeoutResumesBeforeBlockingPhotoKitCancellation` still compiles because of the trailing closure and default arguments.
     - Add a second static `RequestExecutor` instance for the analysis lane. Before submitting on that lane, `loadImageOutcome` does `try await PhotoImageRequestLane.analysisLaunchPermits.acquire()` (`AsyncSemaphore(value: 16)`). The launch operation releases the permit in its `defer` with `Task { await permits.release() }`.
     - The analysis executor's `maximumScheduledCount` equals the permit count, so it never rejects. A cancelled acquire returns `.failed(.cancelled)`.
     - The UI lane keeps today's reject-when-full behavior, now reported as `.failed(.capacity)`. WS-52 replaces it.
  5. `PhotoImageRepository` (`SharedHelpers.swift:261-465`):
     - Add `nonisolated func analysisImage(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode, qualityIntent: PhotoImageQualityIntent, allowNetworkAccess: Bool) async -> PhotoImageLoadOutcome`. It calls `asset.loadImageOutcome(..., lane: .analysis)` with the intent table's delivery mode and timeouts.
     - Analysis intents are non-cacheable after WS-14, so this path skips the cache and in-flight coalescing.
     - Replace the literal timeouts for `.analysisFast` and `.analysis` in the intent `switch` (325-332) with `PhotoAnalysisTimeBudget` (WS-22.4).

```swift
// Added to WS-14's PhotoImageDeliveryDecision.swift. WS-14's decide(imagePresent:…) stays as it is.
enum PhotoImageAnalysisDelivery: Equatable { case accept, reject(PhotoImageLoadFailure) }   // single-shot: never waits

extension PhotoImageDeliveryDecision {
    static let minimumAnalysisSide = 112
    struct AnalysisInput: Equatable {
        var hasImage: Bool, imageMinimumSide: Int, isDegraded: Bool, isCancelled: Bool, isInCloud: Bool
        var errorDomain: String?, errorCode: Int?
        var acceptsDegradedResult: Bool
        var deliveryMode: PHImageRequestOptionsDeliveryMode, allowsNetworkAccess: Bool
    }
    static func decideAnalysis(_ i: AnalysisInput) -> PhotoImageAnalysisDelivery {
        if i.isCancelled { return .reject(.cancelled) }
        if i.hasImage, !i.isDegraded || i.acceptsDegradedResult { return .accept }
        if i.hasImage, i.isDegraded, i.deliveryMode == .fastFormat,
           i.imageMinimumSide >= minimumAnalysisSide { return .accept }        // fastFormat calls back once
        if let code = i.errorCode {
            return .reject(failure(domain: i.errorDomain, code: code, isInCloud: i.isInCloud,
                                   allowsNetworkAccess: i.allowsNetworkAccess))
        }
        return .reject(i.isInCloud && !i.allowsNetworkAccess ? .notLocal : .noResource)   // never wait on single-shot
    }
    /// Both lanes. The UI lane uses it only to label a WS-14 resolution that carries no image.
    static func failure(domain: String?, code: Int?, isInCloud: Bool, allowsNetworkAccess: Bool) -> PhotoImageLoadFailure {
        if domain == PHPhotosErrorDomain, let code {
            switch code {
            case PHPhotosError.Code.networkAccessRequired.rawValue: return .notLocal
            case PHPhotosError.Code.networkError.rawValue: return .downloadFailed
            case PHPhotosError.Code.userCancelled.rawValue: return .cancelled
            default: break   // missingResource / invalidResource fall through to the locality check
            }
        }
        if isInCloud { return allowsNetworkAccess ? .downloadFailed : .notLocal }
        return .noResource
    }
}
```

```swift
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    init(value: Int) { available = max(value, 1) }
    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: { Task { await self.cancelWaiter(id) } }   // runs after the append: the actor is busy until we suspend
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().continuation.resume() }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return } // already granted: caller owns a permit
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
```
- **Edge cases:**
  - The UI lane keeps WS-14's `decide(imagePresent:…)` verbatim, so `.thumbnail`/`.review`/`.fullscreen` semantics and WS-14's decision tests are unchanged; WS-14 owns them. `decideAnalysis(_:)` applies only to the analysis lane.
  - A degraded fast image under 112 px is rejected at once, so the pipeline falls back to `.highQualityFormat`.

**WS-22.3 — Vision feature-print generator with a one-shot CPU retry and revision preflight**
- **Why:**
  - A device Neural Engine or GPU inference-context failure currently writes the photo off with no reason.
  - If a future OS drops revision 1, the whole library silently becomes "unanalyzed".
- **Change:** new file `iOSCleanup/Engines/PhotoFeaturePrintGenerator.swift` containing:
  - `enum PhotoVisionComputePreference: Sendable, Equatable { case automatic, cpuOnly }`.
  - `struct PhotoFeaturePrintResult { let observation: VNFeaturePrintObservation?; let embedding: Data; let elementCount: Int }`. The observation is optional so test doubles can return embeddings without Vision.
  - `typealias PhotoVisionPerform = @Sendable (_ image: CGImage, _ orientation: CGImagePropertyOrientation, _ compute: PhotoVisionComputePreference) throws -> PhotoFeaturePrintResult`.
    - Live implementation `PhotoVisionPerformer.live`: build `PhotoMLBridge.makePinnedFeaturePrintRequest()`; if `.cpuOnly`, call `try PhotoVisionComputeDevice.applyCPU(to: request)`; then `VNImageRequestHandler(cgImage:orientation:options: [:]).perform([request])`.
    - Missing result → throw `NSError(domain: VNErrorDomain, code: VNErrorCode.dataUnavailable.rawValue)`.
  - `enum PhotoVisionComputeDevice`:
    - `static func applyCPU(to request: VNRequest) throws` uses `try request.supportedComputeStageDevices` (a throwing getter on iOS 17), `devices[.main]?.first { if case .cpu = $0 { return true } else { return false } }` and `request.setComputeDevice(cpu, for: .main)`.
    - `static var isCPUForcedByEnvironment: Bool` is true under `#if targetEnvironment(simulator)`.
    - **Move WS-07's simulator CPU code into `applyCPU`** and call it from `makePinnedFeaturePrintRequest()` under the simulator condition, so exactly one place selects the compute device.
  - `enum PhotoVisionRevisionSupport { static var isPinnedRevisionSupported: Bool { VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(PhotoMLBridge.pinnedFeaturePrintRevision) } }`.
  - `protocol PhotoFeaturePrintGenerating: Sendable { func featurePrint(for image: CGImage, orientation: CGImagePropertyOrientation) -> Result<PhotoFeaturePrintResult, PhotoAnalysisFailureKind> }`, with the `final class VisionFeaturePrintGenerator: PhotoFeaturePrintGenerating, @unchecked Sendable` implementation below.
    - The `orientation` parameter is passed `.up` everywhere in this workstream. WS-37 supplies real orientations.

```swift
final class VisionFeaturePrintGenerator: PhotoFeaturePrintGenerating, @unchecked Sendable {
    static let shared = VisionFeaturePrintGenerator()
    static let stickyCPUThreshold = 3
    private let perform: PhotoVisionPerform
    private let isCPUForced: Bool
    private let lock = NSLock()
    private var consecutiveInferenceContextRecoveries = 0
    private var prefersCPU = false
    #if DEBUG
    private(set) var debugCPUFallbackCount = 0
    #endif
    init(perform: @escaping PhotoVisionPerform = PhotoVisionPerformer.live,
         isCPUForced: Bool = PhotoVisionComputeDevice.isCPUForcedByEnvironment) { ... }

    func featurePrint(for image: CGImage, orientation: CGImagePropertyOrientation) -> Result<PhotoFeaturePrintResult, PhotoAnalysisFailureKind> {
        let startOnCPU = isCPUForced || lock.withLock { prefersCPU }
        do { return validated(try perform(image, orientation, startOnCPU ? .cpuOnly : .automatic)) }
        catch let first as NSError {
            guard !startOnCPU else { return .failure(.visionFailed) }        // already on CPU: no second attempt
            do {
                let result = validated(try perform(image, orientation, .cpuOnly))
                noteCPURecovery(afterInferenceContextFailure: Self.isInferenceContextFailure(first))
                return result
            } catch { return .failure(.visionFailed) }
        }
    }
    static func isInferenceContextFailure(_ e: NSError) -> Bool {
        e.domain == VNErrorDomain && [VNErrorCode.internalError, .unsupportedComputeStage, .unsupportedComputeDevice]
            .map(\.rawValue).contains(e.code)
    }
    // validated(): elementCount/byteCount via PhotoEmbeddingContract.isCompatibleObservation → else .failure(.incompatibleEmbedding)
    // noteCPURecovery(true): consecutive += 1; prefersCPU = consecutive >= stickyCPUThreshold. (false): consecutive = 0.
    // A success on .automatic resets consecutive to 0.
}
```
- **Engine preflight:** add `analysisPreflight: (@Sendable () throws -> Void)?` to `PhotoScanEngine.init`.
  - Default: when `assetAnalyzer == nil` (the live Vision analyzer), use `{ guard PhotoVisionRevisionSupport.isPinnedRevisionSupported else { throw ScanError.photoAnalysisUnavailable } }`. Otherwise use `nil`, so WS-07's fixture analyzer and test analyzers skip it.
  - `performScan` calls it first, before `fetchImageAssets()`.
  - Add `case photoAnalysisUnavailable` to `ScanError`, with `errorDescription` "Photo analysis isn't available on this iOS version. Update iOS, then try again."
  - Handle it in the `HomeViewModel` `ScanError` switch (~1266-1285) exactly like `.photoLibraryTemporarilyUnavailable`: `.failed`, message, diagnostic kind `.photoScan`.
- **Edge cases:**
  - CPU and Neural Engine prints differ slightly at fp16 precision. That is why only three *consecutive* inference-context recoveries make the CPU sticky, and a single transient error does not.
  - The sticky flag is per process. It is never persisted.

**WS-22.4 — Analysis pipeline extraction, time budget and Vision lane**
- **Why:** reasons have to be produced where the failure happens, the watchdog must exceed the stage sum, and Vision capacity must wait instead of failing.
- **Change:**
  1. New file `iOSCleanup/Engines/PhotoAssetAnalysisPipeline.swift`:
     - `protocol PhotoAnalysisImageLoading: Sendable` with the `analysisImage(...)` signature from WS-22.2; `PhotoImageRepository` conforms in an extension.
     - `struct PhotoAssetAnalysisPipeline: Sendable { let imageLoader: any PhotoAnalysisImageLoading; let featurePrints: any PhotoFeaturePrintGenerating; static let live = …(PhotoImageRepository.shared, VisionFeaturePrintGenerator.shared); func analyze(_ asset: PHAsset, allowNetworkAccess: Bool) async -> PhotoScanAssetAnalysis }`.
     - Move the body of `analyzeAsset` (`PhotoScanEngine.swift:1009-1090`) here unchanged except for the outcome handling below. Keep calling `PhotoScanEngine.makePerceptualHash` and `makeKeeperSignals`; WS-07 made them internal static. Do not move them.
  2. Move `PhotoScanSynchronousAnalysisExecutor` and `PhotoScanAnalysisRequestState` (`PhotoScanEngine.swift:101-139, 181-234`) into this file, renamed to `PhotoVisionLane`.
     - Replace `submit`'s reject with `try await permits.acquire()` (`AsyncSemaphore(value: 8)`), released in the operation's `defer`.
     - The Vision queue stays 4 wide.
     - Cancellation, while waiting or while scheduled, resolves `.failed(.cancelled)`.
  3. `enum PhotoAnalysisTimeBudget`:
     - `fastLoad = 4`, `fullLoad(allowNetworkAccess:) = network ? 15 : 6`, `vision = 5` (covers the CPU retry), `margin = 5`.
     - `watchdog(allowNetworkAccess:) = fastLoad + 2 * fullLoad + vision + margin`, i.e. 26 s local and 44 s with network.
     - `PhotoScanEngine.swift:596-605` passes `PhotoAnalysisTimeBudget.watchdog` as the coordinator's `timeoutNanoseconds`, and the coordinator's `init` default becomes the local budget (26 s). Change only the default timeout values. Keep WS-06's `watchdogSleep` seam, its DEBUG counters (`debugReleaseAttemptCount`, `debugActiveOperationCount`) and its `ManualWatchdog` tests.
  4. Outcome handling in `analyze`:
     - fast `.image` → use it.
     - fast `.failed(.cancelled)` → return `.failed(.cancelled)`.
     - Any other fast failure → load `.analysis`.
     - Its `.failed(f)` → `return .failed(f.analysisFailureKind)` (no hash, no signals, no Vision).
     - A `UIImage` without a `cgImage` → `.failed(.noResource)`.
     - The confirmation load keeps today's semantics: a failure leaves `keeperSignals = nil` but is **not** an asset failure.
     - Vision `.failure(kind)` → `PhotoScanAssetAnalysis(observation: nil, embedding: nil, perceptualHash: hash, keeperSignals: signals, failure: kind)`.
  5. `PhotoScanEngine`:
     - The default analyzer becomes `{ await PhotoAssetAnalysisPipeline.live.analyze($0, allowNetworkAccess: $1) }`.
     - The coordinator's reject path (259-261) returns `.failed(.capacity)`.
     - Its timeout path (277-279) resolves `.failed(.timedOut)`.
     - Its cancel path (294-298) resolves `.failed(.cancelled)`.
     - Do not otherwise restructure the coordinator; WS-24 does.
  6. `PhotoScanUpdate` (`PhotoScanEngine.swift:18-55`) gains:
     - `var unanalyzedFailures: [String: PhotoAnalysisFailureKind] = [:]`, run-cumulative, with keys equal to `unanalyzedAssetIDs`.
     - The computed `var unanalyzedReasonCounts: [PhotoAnalysisFailureKind: Int]`.
     - The engine inserts `effectiveFailure` next to `unanalyzedAssetIDs.insert` (665-673) and passes it in every yield.
     - In DEBUG, log the reason counts at completion through `diagnosticsLogger`.
  7. If WS-07's `DebugFixtureAnalyzer` returns `.unavailable` on a load failure, change it to `.failed(.noResource)`.
- **Edge cases:**
  - Keep `AssetWorkItem` and the `@unchecked Sendable` wrappers.
  - The pipeline must never take the network unless `allowNetworkAccess` is true (README invariant).

**WS-22.5 — Persist reasons: snapshot entries and the failure ledger**
- **Why:** reasons must survive checkpoints and relaunches so the planner and banner can use them.
- **Change:**
  1. `CachedPhotoAnalysisSnapshot` (`PhotoAnalysisCache.swift:13-264`):
     - Add `let unanalyzedFailureEntries: [PhotoAnalysisFailureEntry]?`, with a coding key, `decodeIfPresent` and an init parameter defaulting to `nil`.
     - Always store `nil` when empty, so the synthesized encoder omits the key and WS-16's golden `AnalysisSnapshotBuilder` output stays byte-identical for inputs without failures.
     - Entries are sorted by `assetID`.
     - Do not bump `schemaVersion` (the field is additive).
     - Pass the field through all three construction sites listed above, plus any site added by WS-17/WS-18 (search for `CachedPhotoAnalysisSnapshot(`).
     - Add `var failureEntriesByID: [String: PhotoAnalysisFailureEntry]`.
  2. In `PhotoAnalysisFailure.swift`, add a pure `struct PhotoAnalysisFailureLedger: Equatable, Sendable` (sketch below).
     - If `iOSCleanup/Views/Home/AnalysisCheckpointState.swift` exists (WS-16), store a `ledger` in it and fold it inside its `fold(update:offsets:)`.
     - Otherwise, store it in `HomeViewModel` next to `checkpointUnanalyzedAssetIDs` (~284) and fold it where that set is folded (~1698-1700).
     - Everywhere `checkpointUnanalyzedAssetIDs` is (re)assigned, keep the ledger in step:
       - scan start (~1141-1143): `startRun(fullRescan:)`
       - restore (~2204): `init(entries:)`
       - the deleted-photo prune (~1600-1604): `retain(presentIDs:)`
       - the snapshot build (~2065): `sortedEntries`
     - After WS-17 the restore goes through `RestoredAnalysisState`; add the entries there.
  3. `HomeViewModel` pass-throughs (a few lines each, no logic):
     - `var unanalyzedReasonCounts: [PhotoAnalysisFailureKind: Int] { ledger.reasonCounts(unanalyzedIDs: checkpointUnanalyzedAssetIDs) }`
     - `unanalyzedICloudCount`, the sum over `isICloud` kinds
     - `unanalyzedDeviceFailureCount`, the sum over `isDeviceFailure` kinds
     - They ride on the existing `publishProgressSnapshot()` refresh, like `unanalyzedPhotoCount`.

```swift
struct PhotoAnalysisFailureLedger: Equatable, Sendable {
    private var baseline: [String: PhotoAnalysisFailureEntry] = [:]   // carried in from the snapshot at run start
    private(set) var entriesByID: [String: PhotoAnalysisFailureEntry] = [:]
    init(entries: [PhotoAnalysisFailureEntry] = []) { entriesByID = Dictionary(entries.map { ($0.assetID, $0) }, uniquingKeysWith: { $1 }) }
    mutating func startRun(fullRescan: Bool) {
        baseline = fullRescan ? [:] : entriesByID
        if fullRescan { entriesByID = [:] }
    }
    /// Idempotent: called with the run-cumulative sets of *every* update, so counts must not grow per fold.
    mutating func fold(evaluatedAssetIDs: Set<String>, runFailures: [String: PhotoAnalysisFailureKind], currentBuild: String) {
        var next = baseline.filter { !evaluatedAssetIDs.contains($0.key) }   // successes and re-attempts leave the baseline
        for (id, kind) in runFailures {
            next[id] = PhotoAnalysisFailureEntry(assetID: id, kind: kind,
                attemptCount: (baseline[id]?.attemptCount ?? 0) + 1, appBuild: currentBuild)
        }
        entriesByID = next
    }
    mutating func retain(presentIDs: Set<String>) { entriesByID = entriesByID.filter { presentIDs.contains($0.key) }; baseline = baseline.filter { presentIDs.contains($0.key) } }
    func reasonCounts(unanalyzedIDs: Set<String>) -> [PhotoAnalysisFailureKind: Int] {
        unanalyzedIDs.reduce(into: [:]) { $0[entriesByID[$1]?.kind ?? .unknown, default: 0] += 1 }
    }
    var sortedEntries: [PhotoAnalysisFailureEntry] { entriesByID.values.sorted { $0.assetID < $1.assetID } }
}
```
- **Edge cases:**
  - Legacy snapshots have unanalyzed IDs with no entries. They count as `.unknown`, and the planner retries them once to learn a reason.
  - Limited-access sessions never write snapshots (WS-20), so the ledger lives in memory only there.

**WS-22.6 — Retry policy in the planner and explicit retries**
- **Why:** every automatic scan re-attempts photos that cannot succeed without the network, which wastes time and battery forever.
- **Change:**
  1. In `PhotoAnalysisFailure.swift`, add `enum PhotoAnalysisRetryPolicy`:
     - `static let maximumAutomaticAttempts = 3`
     - `static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }`
     - `static func automaticRetryIDs(unanalyzedIDs:entriesByID:allowNetworkAccess:currentBuild:) -> Set<String>`, using this per-entry rule:
       - `nil` entry (legacy) → retry.
       - `.timedOut`, `.cancelled`, `.capacity`, `.unknown` → retry while `attemptCount < 3`.
       - `.visionFailed`, `.incompatibleEmbedding` → retry only when `appBuild != currentBuild`.
       - `.notLocal`, `.downloadFailed`, `.noResource` → retry only when `allowNetworkAccess`.
     - **DECISION (owner may override):** transient failures are auto-retried at most three times; Vision failures once per app build; iCloud and missing-resource failures only by an explicit retry.
  2. `PhotoScanResumePlanner.requiredAssetIDs` gains `allowNetworkAccess: Bool = false, currentBuild: String = PhotoAnalysisRetryPolicy.currentBuild`. In both branches (312, 328), replace `previouslyUnanalyzedIDs.intersection(currentAssetIDs)` with `PhotoAnalysisRetryPolicy.automaticRetryIDs(unanalyzedIDs: previouslyUnanalyzedIDs, entriesByID: snapshot.failureEntriesByID, allowNetworkAccess:, currentBuild:).intersection(currentAssetIDs)`.
     - `retryAssetIDs` (explicit) is still unioned unconditionally, so an explicit CTA always forces.
     - After WS-17 the planner runs as a nonisolated static in `Task.detached`; pass the new arguments there too.
  3. `HomeViewModel`:
     - Pass `allowNetworkAccess` into the planner call (~985-993).
     - Add `func retryUnanalyzedOnDevice()`, a copy of `retryIncludingICloudPhotos()` (1348-1365) with `allowNetworkAccess: false`, keeping the same `isLegacyFailureRecord` rule and `retryUnanalyzed: true`.
     - Both retries pass every unanalyzed ID as `retryAssetIDs` (today's behavior).
- **Edge cases:**
  - `hasConsistentCompletionState` is untouched. IDs that are not retried stay in `unanalyzedAssetIdentifiers` and in the ledger, so the count and banner remain honest.
  - Never return an empty work set because of the policy when the snapshot is inconsistent. That path still returns `nil` (README invariant).

**WS-22.7 — Home banner: iCloud vs on-device copy**
- **Why:** the current copy blames iCloud for every failure and offers a data-consuming download that cannot fix Vision failures (RT-1).
- **Change:**
  - New file `iOSCleanup/Views/Home/UnanalyzedPhotosBannerModel.swift` (sketch below).
  - Replace the body of `iCloudAnalysisBanner` (`HomeView.swift:528-548`, or where WS-10 moved it) to read `UnanalyzedPhotosBannerModel.make(total: viewModel.unanalyzedPhotoCount, reasonCounts: viewModel.unanalyzedReasonCounts)`:
    - `.downloadAndRescan` sets `showICloudScanConfirmation = true`, which opens the existing "Download and Rescan" dialog (150-160).
    - `.retryOnDevice` calls `viewModel.retryUnanalyzedOnDevice()`.
  - Keep `DuckCard`, `duckBody`/`duckCaption`, `Color.textPrimary`/`textSecondary`/`accentPrimary`. No new visual design.
  - **DECISION (owner may override):** "dominant" means a strict majority. Mixed, transient and legacy sets get the on-device retry first; once reasons are known, iCloud-dominant sets get the download offer.

```swift
struct UnanalyzedPhotosBannerModel: Equatable {
    enum Action: Equatable { case downloadAndRescan, retryOnDevice }
    let systemImage: String, title: String, detail: String, buttonTitle: String, action: Action
    static func make(total: Int, reasonCounts: [PhotoAnalysisFailureKind: Int]) -> Self? {
        guard total > 0 else { return nil }
        let noun = total == 1 ? "photo" : "photos"
        let title = "\(total.formatted()) \(noun) not analyzed"
        let iCloud = reasonCounts.filter { $0.key.isICloud }.values.reduce(0, +)
        let device = reasonCounts.filter { $0.key.isDeviceFailure }.values.reduce(0, +)
        if iCloud * 2 > total {
            return .init(systemImage: "icloud.and.arrow.down", title: title,
                detail: "They're stored in iCloud, so results may be incomplete. Download and Rescan fetches the originals.",
                buttonTitle: "Rescan", action: .downloadAndRescan)
        }
        let detail = device * 2 > total
            ? "PhotoDuck couldn't analyze them on this iPhone, so results may be incomplete."
            : "They couldn't be checked yet, so results may be incomplete."
        return .init(systemImage: "exclamationmark.triangle", title: title, detail: detail,
                     buttonTitle: "Try Again", action: .retryOnDevice)
    }
}
```

**WS-22.8 — Docs**
- Update `ios-cleanup/CLAUDE.md`:
  - `PhotoScanEngine` row: typed failure reasons, CPU retry.
  - `PhotoAnalysisCache` row: failure entries and the retry policy.
  - The "Photo thumbnails must use…" constraint: analysis loads go through `PhotoImageRepository.analysisImage` → `loadImageOutcome(lane: .analysis)`.
  - Add a short "Unanalyzed photos" paragraph listing the reason kinds and the retry policy.
- Update `README.md`'s run-in-simulator note if the pinned-revision probe result changed.

### Tests
All tests run in the simulator unless marked otherwise. They never sleep on wall-clock time; use gates, fakes and deadline polling (WS-06).
- `iOSCleanupTests/PhotoImageDeliveryDecisionTests.swift` (created by WS-14; extend it): table tests on `decideAnalysis(_:)` and `failure(domain:code:isInCloud:allowsNetworkAccess:)`.
  - `testSingleShotFastFormatAcceptsDegradedImageAtAnalysisSize` (side 112 → `.accept`).
  - `testSingleShotFastFormatRejectsSmallDegradedImageImmediately` (111 → `.reject(.noResource)`; the analysis rule has no wait).
  - WS-14's UI-lane tests (`testDegradedNotAcceptedWithoutFallbackWaits` and the rest) stay unchanged and green. They prove UI delivery did not change.
  - `testPhotosErrorCodesMapToFailures`: networkAccessRequired → `.notLocal`, networkError → `.downloadFailed`, userCancelled → `.cancelled`, missingResource local → `.noResource`, missingResource in-cloud without network → `.notLocal`.
  - `testCancelledKeyWins`.
  - `testNilImageInCloudWithoutNetworkIsNotLocal`.
- `iOSCleanupTests/AsyncSemaphoreTests.swift` *new*:
  - `testAcquireWaitsInsteadOfFailingWhenExhausted`: value 1, second acquire suspends until release; poll `debugWaiterCount` with a deadline.
  - `testReleaseResumesWaitersInFIFOOrder`.
  - `testCancelledWaiterThrowsAndDoesNotConsumeAPermit`.
- `iOSCleanupTests/PhotoFeaturePrintGeneratorTests.swift` *new*: fake `PhotoVisionPerform` records preferences and returns `PhotoFeaturePrintResult(observation: nil, embedding: <2,048 floats>, elementCount: 2_048)`. Construct the generator with `isCPUForced: false`.
  - `testInferenceContextFailureRetriesOnceOnCPU`: `.automatic` throws `NSError(domain: VNErrorDomain, code: 9)`, CPU succeeds. Expect `.success` and preferences `[.automatic, .cpuOnly]`.
  - `testPersistentVisionFailureReportsVisionFailed`: exactly two attempts.
  - `testCPUBecomesStickyAfterThreeConsecutiveInferenceContextRecoveries`: the fourth call's first preference is `.cpuOnly`.
  - `testNonInferenceErrorRecoveredOnCPUDoesNotBecomeSticky` (code 13).
  - `testForcedCPUEnvironmentDoesNotRetry` (`isCPUForced: true` → one attempt).
  - `testIncompatibleElementCountReportsIncompatibleEmbedding` (elementCount 768).
  - `testPinnedRevisionIsSupportedOnThisRuntime`: asserts `PhotoVisionRevisionSupport.isPinnedRevisionSupported`. If it fails in the simulator, report it in the PR; do not skip it.
- `iOSCleanupTests/PhotoAssetAnalysisPipelineTests.swift` *new*: fake `PhotoAnalysisImageLoading` returning scripted outcomes (a 224×224 `CGImage` drawn in the test, as `makeVisionFixture` does) and a fake generator; asset is WS-08's `ConfigurablePhotoScanTestAsset`.
  - `testFastNoResourceFallsBackToFullLoad`.
  - `testNotLocalSkipsVisionAndReportsNotLocal`: generator call count 0.
  - `testVisionFailureKeepsHashAndSignals`: `failure == .visionFailed`, `perceptualHash != nil`, `keeperSignals != nil`.
  - `testCancelledFastLoadReportsCancelled`.
  - `testWatchdogBudgetExceedsStageSum` (26 and 44).
- `iOSCleanupTests/PhotoScanEngineTests.swift`:
  - `testUnanalyzedAssetsCarryTypedReasons`: the injected analyzer maps IDs to `.failed(kind)`. Final update `unanalyzedFailures` and `unanalyzedReasonCounts` match; `unanalyzedAssetIDs == Set(unanalyzedFailures.keys)`; committed counters unchanged. *Forward note (README contract 15):* WS-53 renames these fields to `newlyUnanalyzedFailures`/`newlyUnanalyzedAssetIDs`, deletes `unanalyzedReasonCounts`, and rewrites this test to accumulate updates with its `PhotoScanUpdateAccumulator`. WS-53 owns that change; write the assertions here against the final update only, so they port mechanically.
  - `testLegacyUnavailableAnalysisReportsUnknown`.
  - `testUnsupportedRevisionFailsScanWithTypedError`: `analysisPreflight` throws, the stream throws `ScanError.photoAnalysisUnavailable`, analyzer call count 0.
  - Extend `testAnalysisWatchdogBoundsHungOperations` with `XCTAssertEqual(first.failure, .timedOut)`.
- `iOSCleanupTests/PhotoAnalysisFailureLedgerTests.swift` *new*:
  - `testFoldIsIdempotentAcrossCumulativeUpdates`: fold the same sets 5 times → attemptCount 1.
  - `testAttemptCountIncrementsOncePerRun` (two runs → 2).
  - `testSuccessRemovesEntry`.
  - `testRetainDropsDeletedAssets`.
  - `testSnapshotRoundTripPreservesFailureEntries`.
  - `testLegacySnapshotWithoutEntriesDecodes`.
  - `testUnknownKindFromNewerBuildDecodesAsUnknown` (hand-written JSON with `"kind":"futureReason"`).
  - `testRepairAndGenerationStampingPreserveEntries`.
  - `testEmptyEntriesAreNotEncoded`: the JSON has no `unanalyzedFailureEntries` key.
  - Planner:
    - `testPlannerDoesNotRequeueNotLocalOnPlainRescan`.
    - `testPlannerRequeuesEverythingOnExplicitRetry` (`retryAssetIDs`).
    - `testPlannerRetriesVisionFailureOncePerBuild` (same build → excluded; new build → included).
    - `testPlannerStopsAutoRetryingTimeoutsAfterThreeAttempts`.
    - The existing `testCompletedScanResumePlannerRetriesPreviouslyUnanalyzedAssets` must stay green (legacy, no entry → retried).
- `iOSCleanupTests/UnanalyzedPhotosBannerModelTests.swift` *new*:
  - `testDownloadOfferedOnlyForStrictICloudMajority` (5 of 10 → retryOnDevice; 6 of 10 → downloadAndRescan).
  - `testDeviceFailuresOfferOnDeviceRetry`.
  - `testLegacyUnknownOffersOnDeviceRetry`.
  - `testSingularTitle` ("1 photo not analyzed").
- `iOSCleanupTests/HomeViewModelTests.swift` (WS-07): `testRetryUnanalyzedOnDeviceScansWithoutNetwork`. Through `HomeViewModelDependencies.makePhotoScanEngine`, capture the engine's `allowNetworkAccess == false` and `requiredAssetIDs ⊇` the unanalyzed IDs.
- **Device-only:** the CPU retry on real Vision failures, fastFormat degraded behavior, and iCloud reason mapping (Device QA below).

### Acceptance criteria
- [ ] Every unanalyzed asset in a `PhotoScanUpdate` has an entry in `unanalyzedFailures`. `.capacity` never appears in engine tests under load (`testUnanalyzedAssetsCarryTypedReasons`, plus WS-24's pipeline tests later).
- [ ] A Vision inference-context error is retried once on the CPU; the fake-performer tests pass.
- [ ] The simulator Vision probe outcome is recorded in the PR (skip or pass).
- [ ] A scan with an unsupported pinned revision fails with `ScanError.photoAnalysisUnavailable` and never marks photos unanalyzed.
- [ ] `.notLocal`, `.downloadFailed` and `.noResource` assets are not re-queued by automatic scans; explicit retries re-queue everything (planner tests).
- [ ] The watchdog default is `PhotoAnalysisTimeBudget.watchdog` (26 s local, 44 s network).
- [ ] The Home banner offers "Download and Rescan" only when iCloud reasons are a strict majority; otherwise "Try Again" runs with the network off (banner model tests and the HomeViewModel test).
- [ ] Snapshots without failures encode byte-identically to before. WS-16's golden test is unchanged and green.
- [ ] `analyzerVersion` and `embeddingVersion` are unchanged.
- [ ] Full suite green, zero warnings, CLAUDE.md updated.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. **Normal library (≥1,000 photos, Full access), Deep Clean.**
   - Expect zero `visionFailed` in the DEBUG completion log.
   - Per-item p50 must be within 10% of the WS-09 baseline.
   - Record `debugCPUFallbackCount`.
2. **iCloud "Optimize iPhone Storage" library, Airplane Mode, Deep Clean.**
   - The banner reads "…stored in iCloud…" with "Rescan".
   - The DEBUG log shows mostly `notLocal`.
3. **Same library, still offline: tap Rescan → Download and Rescan.**
   - Reasons become `downloadFailed`, and the banner still offers the download.
4. **Back online: Download and Rescan.** The unanalyzed count drops.
5. **Add one photo so an automatic incremental scan starts.** The DEBUG plan log shows `required=1`: iCloud failures were not re-queued.
6. **fastFormat check.** Record `fastDegradedCount` / total, i.e. whether fastFormat marked local thumbnails degraded (answers SCAN-14's verify-first question).

### Pitfalls and out of scope
- Do not add hash-only grouping as a Vision fallback (runtime RT-1 suggestion). The CPU retry covers v1, and hash-only groups would bypass the policy services.
- Do not persist reasons in SQLite (`PhotoAssetAnalysisCacheRecord`). The planner reads the JSON snapshot, and the ML store redesign is WS-46 (chapter 10).
- The UI lane's reject-when-full, `CancellationExecutor`'s dropped cancels and UI lane separation are WS-52 (chapter 11). Keep the analysis-lane executor a separate instance so WS-52 can replace the UI lane alone.
- Completion sheet, `categoryNote`, results empty state, hero label and notifications ("Scan incomplete", never "clean") are WS-31 (chapter 07), using the reason counts exposed here.
- Request timeout mechanics (cancellable timers) are WS-24. Here, change only the timeout values.
- Orientation-correct Vision input and blur metric changes are WS-37 (chapter 08), which owns the single `analyzerVersion` bump.
- Scans never use the network by default. `retryUnanalyzedOnDevice()` must pass `allowNetworkAccess: false`.
- Keep `activeScanID` fencing and the run lock untouched in `HomeViewModel`. The new retry calls the existing `scanPhotos(...)` entry point.
- **Reconciliation (README contract 26):** `PhotoImageDeliveryDecision`, `PhotoImageDeliveryAction`, `PhotoImageLoadResult` and `PhotoImageDeliveryDecisionTests.swift` come from WS-14. This workstream only adds `PhotoImageLoadFailure`, `PhotoImageLoadOutcome`, `PhotoImageAnalysisDelivery` and an extension with `decideAnalysis(_:)` and `failure(...)`. It moves the body of WS-14's `loadImageResult` and extends WS-14's `resolve`/`cancel` signatures rather than replacing them.
- **Reconciliation (README contract 8):** `PhotoImageRequestState` is still in `SharedHelpers.swift` here. WS-24.5 moves it into WS-10's existing `iOSCleanup/Utilities/PhotoKitRequestState.swift`.
- **Reconciliation (WS-06 watchdog, chapter 02 final):** WS-22.4 changes only the coordinator's default timeout values (26 s local, 44 s network). WS-06's `watchdogSleep` seam, its DEBUG counters and its `ManualWatchdog` tests stay unchanged.
- **Reconciliation (lane ownership):** WS-52 builds the UI lane on its own `PhotoImageLaunchLane`, not on `AsyncSemaphore`. Keep `PhotoImageRequestLane.analysisLaunchPermits` a separate instance so WS-52 can leave this lane alone.
- **Reconciliation (README contract 15):** WS-53 later renames `unanalyzedFailures` to `newlyUnanalyzedFailures` and deletes the computed `unanalyzedReasonCounts` (the consumer derives counts from the ledger). It also replaces the ledger's cumulative `fold(evaluatedAssetIDs:runFailures:currentBuild:)` with a delta fold. WS-53 updates this workstream's tests and call sites. Do not add production readers of `PhotoScanUpdate.unanalyzedReasonCounts`; `HomeViewModel` reads its counts from the ledger.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-03 | partially | **Confirmed:** revision-only request (PhotoMLBridge.swift:44-48); the catch drops the embedding but keeps the hash (PhotoScanEngine.swift:1080-1087); unanalyzed is inferred from a nil embedding (665-673); the simulator test skips on code 9; the planner re-queues everything (PhotoAnalysisCache.swift:312, 328). **Severity** is P2: device Vision normally works, and the simulator half (CPU in the simulator plus the fixture analyzer) is WS-07. **Plan changes:** `setComputeDevice` only (iOS 17 per D-MIN-OS; `usesCPUOnly` would warn at 17); sticky CPU only after 3 consecutive inference-context recoveries, because CPU and ANE prints differ; `supportedRevisions` preflight via a typed `ScanError`; reasons persisted in the JSON snapshot; the DEBUG analyzer stays in WS-07. |
| FSA-03 (merged into SCAN-03) | partially | The engine half (reason enum, CPU retry, reason counts, iCloud vs device banner) is here. Its completion, empty-state and hero copy moves to WS-31. Enum names unified: `imageUnavailableLocally` → `notLocal`, `imageLoadFailed` → `downloadFailed`/`noResource`. Optional hash-only grouping rejected (lead note). HomeView citations (104-106, 528-548) confirmed. |
| SCAN-14 | partially | **Confirmed:** SharedHelpers.swift:325-332 (fastFormat, no degraded, 4 s); 586-600 (a degraded image with no error waits); 36-46/599-609 (cap 16 → instant nil); PhotoScanEngine.swift:204 (Vision cap → `.unavailable`); 79-84 (dropped cancels); the 4 + 6 + 6 s worst case exceeds the 15 s watchdog. **Unreachable:** the coordinator overload (259-261), because slots are released before resolving; it is mapped to `.capacity` rather than converted to a wait, since WS-24 owns the coordinator and the existing exactly-once test relies on rejection. **Unverified:** the "7 h" figure (device check in WS-22.0). **Plan changes:** the attempt count lives in the snapshot ledger, not `PhotoAssetAnalysisCacheRecord`; dropped cancels go to WS-52; an explicit CTA always forces. |

---

## WS-23 — Incremental and retry scan correctness

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-08, WS-16, WS-22 | no | `ws/23-incremental-scan-correctness` |

**Primary files:** `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Engines/PhotoMLStore.swift`, `iOSCleanup/Views/Home/AnalysisCheckpointState.swift`, `iOSCleanup/Views/Home/PhotoResultsStore.swift`, `iOSCleanup/Engines/PhotoScanTimeline.swift` *new*, `iOSCleanup/Engines/PhotoScanResidentFeatures.swift` *new*, `iOSCleanup/Engines/PhotoScanWorkingSet.swift` *new*, `iOSCleanup/Engines/PhotoScanContextStream.swift` *new*, `iOSCleanup/Views/Home/PhotoGroupMerge.swift` *new*, `iOSCleanupTests/PhotoScanEngineTests.swift`, new test files listed below
**Findings covered:** SCAN-06 (P1, confirmed), SCAN-07 (P2, partially), SCAN-08 (P1, confirmed)
**Decisions applied:**
- D-UPDATE-DELTAS: updates stay cumulative. `affectedAssetIDs` is a computed property derived from cumulative fields, so it cannot be lost to `bufferingNewest(1)`.
- D-REANALYSIS: no `analyzerVersion` bump. Candidate selection is not analysis semantics.

### Goal
In incremental, resume and retry passes, every target is compared with every processed or cached photo inside ±60 min (subject to the existing 480-inspected / 120-compared caps), whatever the processing order. Cached context-to-context pairs are evaluated, so the engine re-forms merged groups. Home's merged groups are pairwise disjoint. Resident embeddings are bounded by a constant (4,096 by default) independent of library size.

### Current behavior (verified)
- `PhotoScanEngine.swift:459-486`: the incremental plan splits `incrementalAssets` into required and context. `await mlBridge.cachedAssetAnalyses(for: contextAssets)` (470-472) loads every context row, including its 8 KB embedding, in one call. Uncached context becomes targets (478-485).
- `PhotoMLStore.swift:678-778`: `loadValidAssetAnalyses` runs one SELECT per lookup and copies each blob into `Data`.
- `PhotoScanEngine.swift:553, 558-580`: all cached context is appended to `orderedProcessedIDs` first and its embeddings copied into `embeddingsByID`. Targets are appended later (845).
- `PhotoScanEngine.swift:1848-1913`: `genericCandidateIDs` walks `orderedProcessedIDs.suffix(480).reversed()` and `break`s at the first older candidate more than 60 min away (1881-1884). This assumes append order is chronological, which is false in incremental mode.
  - Trace `[A', B', A]` (A'/A in January, B' in June, then target B): B's walk hits A first, which is months older, and breaks, so B never sees B'.
  - With more than 480 context rows, early-dated context is never inspected at all.
- `PhotoScanEngine.swift:848-862`: positional eviction removes only index `count − 481` per target, so context rows `0..N−481` stay resident for the whole scan. The comment at 855-859 itself warns about ~400 MB and jetsam.
- `PhotoScanEngine.swift:864-876`: screenshots have their own FIFO retention (`maxRetainedScreenshotFeaturePrints = 1_000`).
- `PhotoScanEngine.swift:1581`: the context window is `visualSessionWindowSeconds` (30 min) while the selector uses `extendedVisualSessionWindowSeconds` (60 min) (`SimilarityPolicyTypes.swift:235-236`).
- `PhotoScanEngine.swift:727-732`: pair keys are only (target, candidate). Context-to-context pairs are never evaluated.
- `SimilarityPolicyServices.swift:745-779`: `formClusters` seeds greedily and tracks `assignedIDs`, so clusters from one run are already disjoint. `784-799`: complete-link growth requires `links.count == cluster.count`.
- `HomeViewModel.swift:1708-1714` (moved into `PhotoResultsStore`/`AnalysisCheckpointState` by WS-16): preserved groups are kept if they are disjoint from `update.evaluatedAssetIDs` (targets only), and `update.groups` is appended. {A,B} survives next to a new {C,A}, so A is in two groups. `1716-1728`: screenshot and blurry merges also use evaluated IDs, and stay that way.
- Existing incremental tests: `testIncrementalScanAnalyzesNewAssetAndBoundedSessionContext` (598-633) and `testWarmIncrementalScanReusesUnchangedContextAnalysis` (635-706). The selector test `testCandidateSelectorReservesExtendedWindowCoverage` (1891-1934) uses the `orderedProcessedIDs:` signature.

### Implementation plan

**WS-23.1 — Chronological timeline and a nearest-first selector**
- **Why:** removes the append-order assumption (SCAN-06), so incremental targets see both older and newer neighbors.
- **Change:** new file `iOSCleanup/Engines/PhotoScanTimeline.swift`.
  - `extension Array where Element == PHAsset { func sortedChronologically() -> [PHAsset] }`: sort by `(creationDate ?? .distantPast, localIdentifier)`. Use it for `targetAssets` in both the full and incremental plans (replacing `sortedByCreationDate()` at 482 and in `prioritizedAssets`' return). Leave `sortedByCreationDate` itself unchanged for other callers.
  - `struct PhotoScanTimeline`:
    - Entries `(date: Date, id: String)` ordered by `(date, id)`, stored in an array with a `head` index for pruning.
    - `mutating func insert(id:date:)`: binary search, upper bound.
    - `func indexBefore(date:id:) -> Int?`: the last entry `< (date, id)`.
    - `func indexAfter(date:id:) -> Int?`: the first entry `> (date, id)`.
    - `subscript`, `startIndex`/`endIndex`.
    - `mutating func prune(olderThan cutoff: Date) -> [String]`: advances `head` and returns the removed IDs. Compact the storage when `head > 4_096 && head * 2 > entries.count`.
    - Only assets with a non-nil capture date are inserted. Nil-date assets were never generic candidates.
  - Move `PhotoScanCandidateSelector` (`PhotoScanEngine.swift:1848-1913`) into this file, with the signature `genericCandidateIDs(for:timeline:descriptorsByID:)`:

```swift
guard let date = descriptor.captureTimestamp else { return [] }
var older = timeline.indexBefore(date: date, id: descriptor.id)
var newer = timeline.indexAfter(date: date, id: descriptor.id)
var inspected = 0; var primary: [String] = []; var extended: [String] = []
while inspected < SimilarityThresholds.maxCandidateAssetsInspected {
    let dOld = older.map { date.timeIntervalSince(timeline[$0].date) }   // >= 0
    let dNew = newer.map { timeline[$0].date.timeIntervalSince(date) }   // >= 0
    let takeOlder: Bool
    switch (dOld, dNew) {
    case let (o?, n?): takeOlder = o <= n        // ties prefer older: identical to today's full-scan walk
    case (_?, nil):    takeOlder = true
    case (nil, _?):    takeOlder = false
    case (nil, nil):   break                     // exhausted
    }
    guard dOld != nil || dNew != nil else { break }
    let index = takeOlder ? older! : newer!
    let delta = takeOlder ? dOld! : dNew!
    guard delta <= SimilarityThresholds.extendedVisualSessionWindowSeconds else { break }   // nearest is outside ±60 min
    if takeOlder { older = index > timeline.startIndex ? index - 1 : nil }
    else { newer = index + 1 < timeline.endIndex ? index + 1 : nil }
    inspected += 1
    let id = timeline[index].id
    guard id != descriptor.id, let candidate = descriptorsByID[id], !candidate.isScreenshot,
          abs(descriptor.aspectRatio - candidate.aspectRatio) <= SimilarityThresholds.majorAspectRatioMismatch
    else { continue }
    if delta <= SimilarityThresholds.visualSessionWindowSeconds { primary.append(id) } else { extended.append(id) }
}
// keep today's budget split (lines 1892-1911) verbatim
```
- **Edge cases:**
  - **Full-scan parity.** In a full scan the timeline only contains older entries. With targets sorted by `(date, id)`, the walk visits exactly the entries of today's `suffix(480).reversed()` walk, in the same order, and stops at the same point. The reference-equivalence test enforces this.
  - Equal timestamps are ordered by ID on both sides.

**WS-23.2 — Resident features: time eviction and a hard cap**
- **Why:** bounds embedding memory (SCAN-08) and replaces positional eviction.
- **Change:** new file `iOSCleanup/Engines/PhotoScanResidentFeatures.swift`.
  - `struct PhotoScanResidentFeatures` with:
    - `static let defaultLimit = 4_096` (about 32 MB).
    - `init(limit: Int = defaultLimit, screenshotLimit: Int = SimilarityThresholds.maxRetainedScreenshotFeaturePrints)`.
    - `private(set) var embeddingsByID: [String: Data]` and `featurePrintsByID: [String: VNFeaturePrintObservation]`.
    - Two insertion-order ID queues (`[String]` plus a head index): generic and screenshot.
    - `mutating func insert(id:isScreenshot:embedding:featurePrint:)`.
    - `mutating func evict(_ id: String)`, a no-op for unknown IDs.
    - `private(set) var peakResidentCount`, `capEvictionCount`.
  - Insert rules:
    - A screenshot goes to the screenshot queue and is trimmed to `screenshotLimit` (today's 864-876 rule).
    - Anything else goes to the generic queue.
    - Then, while `embeddingsByID.count > limit`, evict from the generic queue head first, then the screenshot queue head, incrementing `capEvictionCount`.
    - Update `peakResidentCount = max(peak, embeddingsByID.count)` after enforcement.
  - Time eviction: the working set (WS-23.3) calls `evict` for every non-screenshot ID that `timeline.prune(olderThan:)` returns. Screenshot IDs pruned from the timeline keep their embeddings (screenshot hash buckets are time-independent).
  - Burst frames use time eviction. Burst candidates come from `burstIDsByIdentifier` (IDs), and bursts span seconds, so ±60 min retention covers them.
- **Edge cases:**
  - Keep today's rule that a screenshot without a hash or embedding drops its feature print (838-840).
  - When the cap evicts an in-window embedding, affected pairs get a nil distance and are ineligible. That is a safe degrade; count it (`capEvictionCount`, DEBUG log).

**WS-23.3 — `PhotoScanWorkingSet`: one self-contained per-asset block, plus context ingestion**
- **Why:**
  - SCAN-07 needs context-to-context pairs.
  - WS-24 must be able to drain into an unchanged per-asset block.
  - `PhotoScanEngine.swift` must not grow.
- **Change:** new file `iOSCleanup/Engines/PhotoScanWorkingSet.swift`.
  - Move the state declared at `PhotoScanEngine.swift:544-556` into `struct PhotoScanWorkingSet`:
    - `assetsByID`, `descriptorsByID`, `keeperSignalsByID`, `pairSignals`, `pairResults`
    - `screenshotIDsByHash`, `burstIDsByIdentifier`
    - a `PhotoScanTimeline`, a `PhotoScanResidentFeatures`
    - `contextIDs: Set<String>`
    - `let pairClassifier = ConservativePairSimilarityClassifier()`
  - Move `comparisonCandidateIDs` (1206-1234) and `featureDistance` (1236-1253) into it as non-mutating helpers.
  - API:
    - `func candidateIDs(for descriptor: SimilarityAssetDescriptor, perceptualHash: UInt64?) -> [String]`
    - `mutating func ingestTarget(_ asset: PHAsset, descriptor: SimilarityAssetDescriptor, analysis: PhotoScanAssetAnalysis, candidateIDs: [String], cachedPairRecords: [SimilarityPairKey: PairSimilarityRecord]) -> PhotoScanTargetIngestResult`. This is exactly today's 695-876 minus the awaited pair-cache fetch, which the engine performs between `candidateIDs` and `ingestTarget`. `PhotoScanTargetIngestResult { newPairRecords, isBlurry, pairCacheHits, pairCacheMisses }`.
    - `mutating func ingestContext(_ asset: PHAsset, analysis: PhotoScanAssetAnalysis)`:
      - Register the descriptor, asset and keeper signals.
      - Insert into resident features (no feature print; embedding only).
      - Add to the screenshot hash bucket (only if screenshot, hash and embedding are all present) and the burst bucket.
      - Compute `candidateIDs` and evaluate them with the same shared `evaluatePairs(...)` routine as targets, passing an empty cache and `recordNewPairs: false`.
      - Retain edges with the same per-asset limits (24 generic, 39 burst).
      - Insert into the timeline and `contextIDs`.
    - `mutating func prune(frontier: Date?)`: `for id in timeline.prune(olderThan: frontier − extendedVisualSessionWindowSeconds) where descriptorsByID[id]?.isScreenshot == false { resident.evict(id) }`.
  - Extract the shared `private mutating func evaluatePairs(for descriptor:candidateIDs:cachedPairRecords:recordNewPairs:) -> (records, hits, misses)` from 734-824 so target and context paths cannot diverge.
  - The engine keeps `evaluatedAssetIDs`, `unanalyzedAssetIDs`, counters and `blurryAssets`. `makeGroups` reads the working set's maps; its signature takes the working set by value, or its fields, unchanged otherwise.
  - Delete `orderedProcessedIDs`, the positional eviction (848-862) and the old screenshot retention loop (864-876); the resident features own them now.
  - Add `#if DEBUG` `private var lastPeakResidentEmbeddingCount = 0` on `PhotoScanEngine`, set at scan end, plus `func debugPeakResidentEmbeddingCount() -> Int`.
  - Add `residentEmbeddingLimit: Int = PhotoScanResidentFeatures.defaultLimit` to `PhotoScanEngine.init`.
- **Edge cases:**
  - **No double evaluation.** Context is ingested in ascending date order, and all context with date ≤ T + 60 min is ingested before target T. So when context C is ingested, no processed target is within 60 min of C, and later context is not yet in the timeline. Each unordered pair is therefore evaluated exactly once. Screenshot and burst buckets are time-independent: a late context screenshot compares with earlier targets in its bucket, which is correct because those targets never saw it.
  - **Context-to-context pairs never read or write the pair cache.** ML-05 shows a per-asset SQLite lookup costs more than recomputing, and WS-46 removes the cache. They use `PhotoEmbeddingValueDistance.normalizedDistance` unchanged. Do not switch to vDSP, here or later: WS-46 and WS-53 both decline it, because Float accumulation could flip a threshold-boundary pair (invariant 22). WS-53 records it in `spec/BACKLOG.md`, to be revisited only with a bit-exact threshold study.

**WS-23.4 — Stream context in bounded chunks; widen the context window**
- **Why:** SCAN-08. A 5,000-photo retry in a 50k library preloads ~30k embeddings, about 240 MB.
- **Change:**
  1. `PhotoMLStore`:
     - Add `func validAssetAnalysisIDs(for lookups: [PhotoAssetAnalysisCacheLookup]) throws -> Set<String>`. It uses the same join and metadata checks as `loadValidAssetAnalyses` but selects `length(features.embedding)` instead of the blob. SQLite answers `length()` from the record header without reading overflow pages.
     - Compare that length with `PhotoEmbeddingContract.expectedByteCount(for:)`.
     - Extract the shared metadata validation into a private helper so the two queries cannot drift.
  2. `PhotoMLBridge`: add `func cachedAssetAnalysisIDs(for assets: [PHAsset]) async -> Set<String>` (lookups as in 155-165; on error → `recordPersistenceFailure` and `[]`, exactly like `cachedAssetAnalyses`).
  3. New file `iOSCleanup/Engines/PhotoScanContextStream.swift`: `struct PhotoScanContextStream { static let maximumChunkSize = 512; init(assets: [PHAsset]) /* already chronological */; var isExhausted: Bool; mutating func nextChunk(through bound: Date) -> [PHAsset]? }`. It returns up to 512 next assets whose `creationDate ?? .distantPast <= bound`, or nil.
  4. `PhotoScanEngine.performScan`, incremental branch (459-486):
     - `let cachedIDs = await mlBridge.cachedAssetAnalysisIDs(for: contextAssets)`.
     - `targetAssets = (required + contextAssets.filter { !cachedIDs.contains($0.localIdentifier) }).sortedChronologically()`.
     - `contextStream = PhotoScanContextStream(assets: contextAssets.filter { cachedIDs.contains($0.localIdentifier) })`.
     - Delete the `cachedContextAssets` array and the preload loop (558-580).
  5. Add a private engine helper `loadContext(through bound: Date, frontier: Date?, stream: inout PhotoScanContextStream, workingSet: inout PhotoScanWorkingSet) async`:
     - Loop `nextChunk(through:)`.
     - `let analyses = await mlBridge.cachedAssetAnalyses(for: chunk)`.
     - `workingSet.ingestContext` for each asset present, in chunk order. Count misses in DEBUG `contextLateMissCount`.
     - After each chunk, `workingSet.prune(frontier: min(frontier, lastIngestedDate))`.
     - Record DEBUG `debugMaxContextChunkSize`.
     - Local vars may be passed `inout` across `await`; actor stored properties may not.
  6. In the per-asset loop, before `candidateIDs` for target `T`: `await loadContext(through: (T.creationDate ?? .distantPast) + extendedVisualSessionWindowSeconds, frontier: T.creationDate, …)`. After `ingestTarget`, call `workingSet.prune(frontier: nextTarget?.creationDate)`.
  7. Before the **final** `makeGroups` (when `processedCount == targetCount`), drain the stream completely: `loadContext(through: .distantFuture, frontier: nil, …)`, with `frontier: nil`, meaning "use the last ingested context date".
  8. `incrementalAssets` (1581): `let window = SimilarityThresholds.extendedVisualSessionWindowSeconds`.
- **Edge cases:**
  - If `cachedAssetAnalysisIDs` fails, every context asset becomes a target, which matches today's failure behavior.
  - A row that disappears between the pre-pass and its chunk is skipped as context (DEBUG count).
  - Nil-date context loads first; its generic selection returns `[]`, as today.
  - Pending analysis results in WS-24's lookahead are not resident embeddings. The M1 bound (4,096) is on the working set.

**WS-23.5 — Disjoint output, `affectedAssetIDs` and `PhotoGroupMerge`**
- **Why:** SCAN-07. After an incremental run, A can appear in {A,B} (preserved) and {C,A} (new).
- **Change:**
  1. `PhotoScanUpdate`: `var affectedAssetIDs: Set<String> { evaluatedAssetIDs.union(groups.lazy.flatMap { $0.assets.map(\.localIdentifier) }) }`. It is computed, so nothing extra is carried. WS-53 later deletes it; its consumer then derives the same set as `runEvaluated ∪ members(update.groups)` (README contract 15).
  2. `makeGroups` (1255-1419): before `return`, add `assert(PhotoGroupDisjointness.isPairwiseDisjoint(groups), "formClusters produced overlapping groups")`. With context-to-context edges, the engine now emits context-only clusters too, and that is intended.
  3. New file `iOSCleanup/Views/Home/PhotoGroupMerge.swift`:

```swift
enum PhotoGroupDisjointness {
    static func isPairwiseDisjoint(_ groups: [PhotoGroup]) -> Bool { /* single pass over a Set of claimed IDs */ }
}
enum PhotoGroupMerge {
    /// Keeps untouched preserved groups, replaces the rest with the engine's groups, and never lets an asset
    /// appear twice. A re-formed group whose members were not re-analyzed keeps its preserved instance (same UUID).
    static func merge(preserved: [PhotoGroup], updateGroups: [PhotoGroup],
                      evaluatedAssetIDs: Set<String>, affectedAssetIDs: Set<String>) -> [PhotoGroup] {
        let preservedByMembers = Dictionary(preserved.map { (Set($0.assets.map(\.localIdentifier)), $0) },
                                            uniquingKeysWith: { first, _ in first })
        let replacements = updateGroups.map { group -> PhotoGroup in
            let members = Set(group.assets.map(\.localIdentifier))
            guard members.isDisjoint(with: evaluatedAssetIDs), let kept = preservedByMembers[members] else { return group }
            return kept
        }
        var claimed = Set(replacements.flatMap { $0.assets.map(\.localIdentifier) })
        var untouched: [PhotoGroup] = []
        for group in preserved {                       // legacy snapshots may already overlap: first one wins
            let ids = group.assets.map(\.localIdentifier)
            guard affectedAssetIDs.isDisjoint(with: ids), claimed.isDisjoint(with: ids) else { continue }
            claimed.formUnion(ids); untouched.append(group)
        }
        return untouched + replacements               // same order as today: preserved first
    }
}
```
  4. Replace the group filter WS-16 moved (search `replacedIDs.isDisjoint` or `preservingGroups.filter`; originally `HomeViewModel.swift:1708-1714`) with `PhotoGroupMerge.merge(preserved: preservingGroups, updateGroups: update.groups, evaluatedAssetIDs: update.evaluatedAssetIDs, affectedAssetIDs: update.affectedAssetIDs)`. Screenshot and blurry merges keep `update.evaluatedAssetIDs`. Context assets are never re-classified into categories.
- **Edge cases:**
  - Do **not** include all context IDs in `affectedAssetIDs` (verifier correction). Extended-visual groups span up to 60 min, so a preserved {X, A} with X outside the context would be dropped and never re-formed.
  - **Known limitation:** a preserved group member more than 60 min from every target can end up ungrouped when its partner joins a new group. The next full rescan normalizes it. Document this in CLAUDE.md.
  - Every group rebuild still goes through `PhotoGroup.init`. The merge only selects instances and never edits plans (README invariant).

**WS-23.6 — Docs**
- Update CLAUDE.md:
  - `PhotoScanEngine` row: chronological timeline, context streamed in ≤512 chunks, resident embeddings ≤4,096, context-to-context pairs, disjoint output.
  - `PhotoAnalysisCache` row: "±60 min comparison context".
  - Note the known limitation above.
- In the PR summary, flag that README invariant 17's wording ("orderedProcessedIDs, genericCandidateIDs early break") now refers to the timeline. The drain order stays strictly chronological.

### Tests
All run in the simulator. Engine tests use a temp `PhotoMLStore(directoryURL:)` wrapped in `PhotoMLBridge(store:)`, as `testWarmIncrementalScanReusesUnchangedContextAnalysis` does, plus WS-08's `ConfigurablePhotoScanTestAsset` and `TestEmbeddings` (`base(seed:)`, `offset(_:rmsDistance:seed:)`, `data(_:)`). Seed large caches directly with `bridge.persistFeatureRecords` / `bufferAssetAnalyses` + `flushBufferedWrites()` rather than a first scan.
- `iOSCleanupTests/PhotoScanTimelineTests.swift` *new*:
  - `testTimelineOrdersByDateThenIdentifier`.
  - `testPruneRemovesOnlyEntriesOlderThanCutoff`.
  - `testSelectorMatchesLegacyWalkForChronologicalProcessing`: copy today's `genericCandidateIDs` (1849-1912) into the test as `legacyCandidateIDs`. Build 2,000 seeded-random descriptors (dates with duplicates, 10% screenshots, mixed aspect ratios) sorted `(date, id)`. For each index, feed the legacy function the prefix and the new function a timeline of the prefix, and assert equal arrays.
  - `testSelectorWalksNearestFirstInBothDirections`.
  - `testSelectorStopsAfterInspectionCap`.
  - Port `testCandidateSelectorReservesExtendedWindowCoverage` to the timeline signature with identical assertions.
- `iOSCleanupTests/PhotoScanResidentFeaturesTests.swift` *new*:
  - `testResidentCountNeverExceedsLimit`.
  - `testScreenshotsKeepTheirOwnRetention`.
  - `testEvictingUnknownIDIsNoOp`.
  - `testPeakCountTracksMaximum`.
- `iOSCleanupTests/PhotoScanIncrementalTests.swift` *new*:
  - `testRetriedTargetsCompareWithCachedNeighborsAcrossDistantDates`: seed A' (t = 1 s) and B' (t = 1e7 + 1 s); the incremental scan has required {A (t = 0), B (t = 1e7)} with identical embeddings per pair. Final groups are exactly {A, A'} and {B, B'}.
  - `testTargetComparesWithContextBeyond480Positions`: seed 600 distinct context assets at t = 0…599 s, where X (t = 0) is identical to target T (t = 0.5 s). Expect a group {T, X}. This fails on today's code.
  - `testNewPhotoJoinsExistingGroupAsOneDisjointGroup`: deep scan A, B (identical, 3 s apart), then incremental with required [C] (identical, 10 s later). The final update has exactly one group {A, B, C}; `affectedAssetIDs ⊇ {A, B, C}`; `PhotoGroupMerge` of the first scan's groups with this update yields one group. *Forward note (README contract 15):* WS-53 deletes `affectedAssetIDs` and renames `evaluatedAssetIDs`; it rewrites this test to accumulate updates and derive the affected set itself. WS-53 owns that change.
  - `testContextWindowIncludesExtendedSession`: context at +45 min is compared.
  - `testLargeRetryPassKeepsResidentEmbeddingsBounded`: 3,000 cached context at 1-minute spacing (50 h) and 50 targets, one per hour, each identical to its t + 30 s neighbor. `debugPeakResidentEmbeddingCount() ≤ 400` (the old code holds 3,000), every target is grouped with its neighbor, and `debugMaxContextChunkSize ≤ 512`.
  - `testInjectedResidentLimitIsHonored` (limit 128 → peak ≤ 128).
- `iOSCleanupTests/PhotoGroupMergeTests.swift` *new*:
  - `testMergeDropsPreservedGroupsTouchingAffectedAssets`.
  - `testMergeKeepsPreservedInstanceForUntouchedIdenticalMembership` (same UUID).
  - `testMergeHealsLegacyOverlap`.
  - `testMergedGroupsArePairwiseDisjoint`: 200 seeded random scenarios; assert `isPairwiseDisjoint`.
- **Regression net:**
  - WS-08's `PhotoScanEngineEndToEndTests` and benchmark (7) stay green.
  - Existing incremental tests (598-706) stay green.
  - The `testIncrementalScanAnalyzesNewAssetAndBoundedSessionContext` expectations hold: "far" is 2.8 h away.

### Acceptance criteria
- [ ] In incremental mode, a target compares with cached context both older and newer than itself, and with context more than 480 positions away (the two engine tests).
- [ ] The new selector equals the legacy walk for chronological processing (reference-equivalence test), and WS-08 end-to-end groups are unchanged.
- [ ] An incremental run produces {A, B, C}, not {A, B} + {C, A}. The merged Home groups are pairwise disjoint, and the `makeGroups` DEBUG assertion never fires in the suite.
- [ ] Context loads happen in chunks of ≤512 IDs. Peak resident embeddings stay at or below the limit (4,096 default) and are independent of library size (`testLargeRetryPassKeepsResidentEmbeddingsBounded`).
- [ ] The context window is 60 min.
- [ ] Context-to-context pairs never touch the pair cache.
- [ ] `PhotoScanEngine.swift` is smaller than before this PR.
- [ ] Zero warnings, full suite green, CLAUDE.md updated.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. **Incremental merge.** Take 3 near-identical photos, then run a scan. Take a 4th ten seconds later and return to PhotoDuck so the automatic incremental scan runs. Similar Photos shows **one** group of 4, and no photo appears in two cards.
2. **Large retry on a 30k+ iCloud Optimize library, with Instruments Allocations attached.**
   - Run "Download and Rescan" with thousands of unanalyzed photos.
   - Peak memory must be recorded and the app not jetsammed.
   - The DEBUG `peak_resident_embeddings` log is ≤4,096.
   - Groups found by the retry include cached neighbors.

### Pitfalls and out of scope
- Do not touch the main loop's batching. WS-24 replaces it and drains into `PhotoScanWorkingSet` unchanged, so keep `candidateIDs` → (await pair cache) → `ingestTarget` → `prune` as the only per-target sequence.
- Do not change thresholds (WS-39), the pair classifier, or the refresh schedule (WS-53).
- Compact edges and window finalization are WS-53 (chapter 11). `descriptorsByID` and `pairResults` still grow with the run.
- Removing the per-target pair-cache query is WS-46 (chapter 10).
- Delta updates (SCAN-19) are WS-53. Keep updates cumulative.
- Do not preload anything unbounded: every SQLite read in the incremental path is ≤512 IDs.
- **Reconciliation (README contract 15):** WS-53 renames `evaluatedAssetIDs` to `newlyEvaluatedAssetIDs` and deletes the computed `affectedAssetIDs`. `PhotoGroupMerge.merge(…evaluatedAssetIDs:affectedAssetIDs:)` keeps its signature; WS-53 feeds it run-cumulative sets from `AnalysisCheckpointState`. WS-53 updates `testNewPhotoJoinsExistingGroupAsOneDisjointGroup`.
- **Reconciliation (vDSP):** an earlier draft said vDSP distance belonged to WS-53. WS-53 (and WS-46) decline it because Float accumulation could flip threshold decisions (invariant 22), and it goes to `spec/BACKLOG.md`. No workstream ports `PhotoEmbeddingValueDistance` to vDSP.
- **Forward note (WS-61, chapter 13):** WS-61 builds on `PhotoScanWorkingSet`'s shape (`candidateIDs`/`ingestTarget`/`ingestContext`/`prune`). Keep those names.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-06 | confirmed | Context is appended first (558-580), then targets (845). The selector walks `suffix(480).reversed()` and breaks at the first older candidate >60 min (1856-1884). The [A', B', A] trace is correct, and with more than 480 context rows early context is never inspected. The context window is ±30 min (1581) vs the 60 min selector. The plan follows the reviewer (timeline, binary search, nearest-first, time eviction) plus: `(date, id)` target ordering and a reference-equivalence test for full-scan parity; screenshots on their own retention; bursts time-evicted (they span seconds). **Not adopted:** the verifier's "consult the pair cache for context pairs"; recomputing is cheaper (ML-05) and WS-46 removes the cache. |
| SCAN-07 | partially | The mechanism is confirmed: (target, candidate) keys only (727-732); complete link needs every link (Services:793); the merge filters by evaluated IDs only (HomeViewModel.swift:1708-1714). Engine output within one run is already disjoint (Services:745-779 `assignedIDs`); the overlap comes from the merge. P2: guardrails reject cross-group conflicts, so nothing unsafe is deleted, but cards and counts duplicate. Uses the verifier's correction, `affected = evaluated ∪ members(update.groups)`, not all context. **Added:** keep the preserved instance for identical untouched membership (avoids UUID churn now that context-only groups are re-emitted) and self-healing of legacy overlaps. |
| SCAN-08 | confirmed | `cachedAssetAnalyses` loads every context row with its blob in one call (470-472; PhotoMLStore 678-778), copied into `embeddingsByID` (558-566). Eviction removes one ID per target at `count − 481` (848-861), so early context is never evicted. The fix combines with SCAN-06's timeline: a blob-free ID pre-pass, ≤512-ID chunks bounded by `T + 60 min`, time eviction behind `T − 60 min`, a 4,096 cap and a DEBUG peak counter. |

---

## WS-24 — Scan pipeline throughput and energy hygiene

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-08, WS-23 | yes | `ws/24-scan-pipeline-throughput` |

**Primary files:** `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Engines/FileScanEngine.swift`, `iOSCleanup/Utilities/SharedHelpers.swift`, `iOSCleanup/Utilities/PHAsset+FileSize.swift`, `iOSCleanup/Engines/ScanPauseGate.swift` *new*, `iOSCleanup/Engines/OrderedAnalysisWindow.swift` *new*, `iOSCleanup/Utilities/PhotoKitRequestState.swift` (created by WS-10; extended here), `iOSCleanupTests/PhotoKitRequestStateTests.swift` (created by WS-10; extended here), `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/FileScanEngineTests.swift`, new test files below
**Findings covered:** PERF-02 (P1, confirmed), PERF-14 (P3, partially)
**Decisions applied:**
- D-UPDATE-DELTAS: `bufferingNewest(1)` stays; updates stay cumulative, with the same shape, every 8 drained assets.
- D-REANALYSIS: no version bumps.
- D-SCAN-RESOURCES: `inFlightLimit` is 8 here. WS-25 later reads it from `ScanResourcePolicy`, so read it through one function (`currentInFlightLimit()`).

### Goal
Eight analyses stay in flight continuously. The serial compare, SQLite and regroup work overlaps image loading and Vision. Results are still processed in strict chronological order, so groups are identical. A paused scan performs no periodic wakeups. Resolved PhotoKit requests leave no pending timers. The Large Videos scan uses the same sliding window.

### Current behavior (verified)
State after WS-23. The lock-step loop itself is unchanged since today.
- `PhotoScanEngine.swift:638-676`: `while processedCount < targetCount` slices 8 targets, and `await withTaskGroup` returns only when all 8 finish. Only then does the serial work run:
  - date re-sort (679-688)
  - the per-asset block, now `PhotoScanWorkingSet` calls, with an awaited pair-cache query per asset (730-732)
  - awaited `buffer*` calls (898-900)
  - `makeGroups` at refresh thresholds (902-918)
  - the yield (935-963)
- `PhotoMLBridge.swift:104-135`: `bufferFeatureRecords`, `bufferPairSimilarities` and `bufferAssetAnalyses` `await flushBufferedWrites()` inline at 96/384/96 records, i.e. three SQLite transactions (137-149) on the scan's critical path. `228-237`: a 1.5 s delayed flush otherwise.
- `HomeViewModel.swift:1183-1189`: `await mlBridge.flushBufferedWrites()` runs before every `scheduleSnapshot`. This is the durability boundary and stays.
- `PhotoScanEngine.swift:1001-1007`: `waitWhilePaused()` polls `Task.sleep(100 ms)` while `isPaused`. `HomeViewModel` keeps the paused engine (`activePhotoScanEngine`, 269; pause path 882-915), so a foreground pause wakes the CPU 10×/s indefinitely.
- `SharedHelpers.swift:564`: every image request schedules `DispatchQueue.global().asyncAfter(deadline: .now() + timeout)`, which is never cancelled. `PHAsset+FileSize.swift:709` does the same with 5 s for video sizes.
- `PhotoScanEngine.swift:272-289`: the coordinator creates two `Task.detached` per asset. The timeout task is cancelled when the operation completes (286), so it causes no late wakeup.
- `FileScanEngine.swift:89-90, 163-205`: lock-step batches of 8 (`measurementBatchSize`) with results published every 4 batches. One 5 s `requestAVAsset` timeout stalls the other 7.
- Tests that must stay green:
  - `testScanUpdateCountIsBoundedByBatchCount` (764-789: ≤ ceil(n/8) + 1 updates).
  - `testBufferedProgressCarriesDurableCheckpointIntoResumePlan` (708-762: committed count == `evaluatedAssetIDs.count`).
  - The watchdog tests (473-568).
  - `testScanCancellationPropagatesIntoInFlightAssetAnalysis` (973-1012).
  - WS-08's buffer/pause/progress tests, end-to-end groups and benchmark (7).

### Implementation plan

**WS-24.0 — Verify-first: baseline**
- Read the WS-09 baseline: photos/s, p50/p99 of `analyze.item`, and gaps between `analyze.item` intervals around `engine.drain`/`engine.regroup`/`ml.flush`. Record them in the PR with the expected gain. This measurement does not gate the work: implement WS-24.1–24.6 regardless (WS-25 and WS-28 build on the window and the gate). Re-measure after merge on the same device and put both numbers in the PR.

**WS-24.1 — `ScanPauseGate` replaces polling**
- **Why:** removes the 10 Hz wakeups while paused. WS-25's thermal suspension, WS-27's video-pass quiesce and WS-28's background pause reuse the gate.
- **Change:**
  - New file `iOSCleanup/Engines/ScanPauseGate.swift` (sketch below). The gate is reason-set based from day one (README contract 2). It is open only when no reason is held, so one owner's resume can never lift another owner's pause. Reasons are added additively by later workstreams: `.user` (here), `.thermal` (WS-25), `.videoPass` (WS-27), `.background` (WS-28).
  - `PhotoScanEngine`:
    - `private let pauseGate = ScanPauseGate()`
    - `pause()` → `await pauseGate.pause(.user); await mlBridge.flushBufferedWrites()`
    - `resume()` becomes `async` → `await pauseGate.resume(.user)`. Callers already `await` it.
    - `performScan` start → `await pauseGate.resume(.user)` (replaces `isPaused = false`)
    - `waitWhilePaused()` → `try await pauseGate.waitIfPaused()`. After WS-24.2 it is called only from the loop's drain point.
    - Delete `isPaused` and the polling loop.

```swift
enum ScanPauseReason: Hashable, Sendable {
    case user            // PhotoScanEngine.pause()/resume(). Later: .thermal (WS-25), .videoPass (WS-27), .background (WS-28)
}

actor ScanPauseGate {
    private var reasons: Set<ScanPauseReason> = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var isPaused: Bool { !reasons.isEmpty }
    func isPaused(for reason: ScanPauseReason) -> Bool { reasons.contains(reason) }
    func pause(_ reason: ScanPauseReason) { reasons.insert(reason) }
    func resume(_ reason: ScanPauseReason) {
        reasons.remove(reason)
        guard reasons.isEmpty else { return }
        let resumed = waiters; waiters.removeAll()
        resumed.values.forEach { $0.resume() }
    }
    func waitIfPaused() async throws {
        try Task.checkCancellation()
        guard isPaused else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: { Task { await self.cancelWaiter(id) } }  // enqueued behind this call, so the waiter exists
        try Task.checkCancellation()
    }
    private func cancelWaiter(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    #if DEBUG
    func debugWaiterCount() -> Int { waiters.count }
    #endif
}
```

**WS-24.2 — Ordered sliding window in `performScan`**
- **Why:** PERF-02. Each batch waits for its slowest photo, and serial work runs with nothing in flight.
- **Change:**
  1. New file `iOSCleanup/Engines/OrderedAnalysisWindow.swift`: a pure generic value type (sketch below). Add to `PhotoScanDefaults`:
     - `progressYieldStride = 8`
     - `maximumDrainLookahead = 256` (bounds buffered results to about 4 MB)
     - `func currentInFlightLimit() -> Int { PhotoScanDefaults.analysisBatchSize }` on the engine (WS-25 replaces the body)
  2. Replace 638-963 with one `withThrowingTaskGroup(of: (Int, PhotoScanAssetAnalysis).self)` for the whole run:
     - Seed: `try await drainPoint()`, then `while window.canStart(inFlightLimit:) { start }`. Each child is `(index, await analysisCoordinator.analyze { await assetAnalyzer(item.asset, allowNetworkAccess) })`; keep the WS-09 `analyze.item` signpost inside the child.
     - On every `try await group.next()`:
       1. `window.receive(result, at: index)`.
       2. Top up (`while window.canStart(...)`) only when `await pauseGate.isPaused` is false. This check never parks: a gate closed for any reason only stops new starts.
       3. `while let (i, analysis) = window.popDrainable()`, run the **unchanged** WS-23 sequence for `targetAssets[i]`: `loadContext`, `candidateIDs`, pair-cache fetch, `ingestTarget`, `prune`, counters, `unanalyzedFailures`. There is **no** pause check inside this drain loop, so a pause never parks mid-drain.
       4. **Drain point:** `try await drainPoint()`, a separate `private func` and the only place the loop parks. In this workstream its body is `try await waitWhilePaused()`. When it returns, top up again with the same gate check as step 2, because nothing started while it was parked.
     - Exit the loop when `window.isFinished` (after the final drain and yield; there is no drain point after it).
     - **Exposed for WS-27 (README contract 2):** actor-stored `private(set) var inFlightAnalysisCount = 0`, set to `window.inFlightCount` after every start and every receive and reset to 0 when the loop exits, and `private(set) var isInAnalysisLoop = false`, true from the seed until the task group exits. WS-27.4 extends only `drainPoint()`: while a quiesce is pending and `inFlightAnalysisCount > 0`, it returns without parking, so step 2 keeps top-ups off and the loop keeps receiving and draining. Then it yields, acknowledges and parks.
     - Accumulate `drained` feature/analysis records locally.
     - Every `progressYieldStride` drained assets (checked inside step 3), or when `window.isFinished`:
       - buffer the ML records (WS-24.3 makes this non-blocking)
       - if at a refresh threshold, `makeGroups` inside the `engine.regroup` signpost; on the final slice, drain the context stream first (WS-23.4 step 7)
       - yield the update with `committedProcessedPhotoCount = window.nextIndexToDrain`
     - Keep `await Task.yield()` after each yield.
  3. Delete the per-batch re-sort (679-688). Drain order is index order over `sortedChronologically()` targets.
  4. Cancellation: a thrown `CancellationError` exits the body, and the task group cancels the remaining children. The coordinator's cancel handler resolves them promptly. Do not add `group.cancelAll()` in the success path.

```swift
struct OrderedAnalysisWindow<Result> {
    let count: Int, maximumLookahead: Int
    private(set) var nextIndexToStart = 0, nextIndexToDrain = 0, inFlightCount = 0
    private var pending: [Int: Result] = [:]
    func canStart(inFlightLimit: Int) -> Bool {
        nextIndexToStart < count && inFlightCount < max(inFlightLimit, 1)
            && nextIndexToStart - nextIndexToDrain < maximumLookahead
    }
    mutating func start() -> Int { defer { nextIndexToStart += 1; inFlightCount += 1 }; return nextIndexToStart }
    mutating func receive(_ result: Result, at index: Int) { inFlightCount -= 1; pending[index] = result }
    mutating func popDrainable() -> (index: Int, result: Result)? {
        guard let r = pending.removeValue(forKey: nextIndexToDrain) else { return nil }
        defer { nextIndexToDrain += 1 }; return (nextIndexToDrain, r)
    }
    var isFinished: Bool { nextIndexToDrain == count }
    var pendingCount: Int { pending.count }
}
```
- **Edge cases:**
  - Unanalyzed and analyzed counts are incremented in drain order, not arrival order, so committed counters always describe a chronological prefix.
  - While paused (parked at the drain point), in-flight children finish and their results wait in the group; no new child starts. A pause requested mid-iteration takes effect at that iteration's drain point, after the drainable results were drained and any due update was yielded.
  - `makeGroups` runs with the window already topped up (the top-up happens right after each receive, before the drain), so loads and Vision continue during regroup.
  - An update is still yielded when `targetCount < 8`.

**WS-24.3 — Non-blocking ML buffer flushes with backpressure**
- **Why:** three SQLite transactions every 96 assets sit on the drain path.
- **Change:** in `PhotoMLBridge`:
  - Add `var backpressureRecordCount = 1_024` to WS-08's `PhotoMLWriteBufferTuning` (`.default` keeps every other value).
  - Replace the inline `await flushBufferedWrites()` in the three `buffer*` methods with `enqueueFlush()` when a count threshold is reached.
  - `enqueueFlush()` snapshots and clears the buffers synchronously, adds their size to `inFlightRecordCount`, and chains `flushChain = Task { await previous?.value; await persist(features, pairs, analyses); didFinishFlush(count) }`. This keeps today's order: features, then pairs, then analyses. The chain also serializes flushes, so a later batch's pairs can never be written before an earlier batch's features.
  - After buffering, if `buffered + inFlightRecordCount > backpressureRecordCount`, `await flushChain?.value`.
  - `flushBufferedWrites()`: cancel the delayed timer, `enqueueFlush()` if anything is buffered, then `await flushChain?.value`. Returning therefore still means "everything buffered before this call is persisted", which is the durability boundary `HomeViewModel` and `pause()` rely on.
  - Keep the `ml.flush` signpost around `persist`.

**WS-24.4 — Sliding window in `FileScanEngine.largePhotoAssets`**
- **Why:** one slow `requestAVAsset` stalls seven other measurements.
- **Change:**
  - Replace 163-205 with one `withTaskGroup(of: ResolvedVideo.self)`: seed 8 children, and after each `group.next()` add the next asset while any remain.
  - `processedVideoCount += 1`. Publish progress when `processedVideoCount % measurementBatchSize == 0` or at completion. Publish results every `measurementBatchSize * publicationBatchStride` (32) processed, or at completion, sorted by size as today. Order is irrelevant here.
  - Check `Task.isCancelled` after each `next()` and call `group.cancelAll()`, then keep the existing `try Task.checkCancellation()` after the group.
  - Keep `onUpdate` awaited (WS-50 later makes it non-awaited).
  - Forward note (README contract 25): WS-42 later renames `FileScanUpdate.largeFiles` to `retainedVideos`, changes `FileRepresentativeResolver` to `(asset, remeasureEstimates)`, makes `scan()` return `FileScanResult` and deletes `minimumFileSizeBytes`. Keep the window generic over the resolver call so that change is mechanical. WS-42 updates this loop and `testSlowVideoDoesNotStallOtherMeasurements`.

**WS-24.5 — Cancellable PhotoKit request timers**
- **Why:** 60k–180k `asyncAfter` timers per scan fire after their requests resolved, and each keeps its closure alive until it fires.
- **Change:**
  - Move `PhotoImageRequestState` with its executors (`SharedHelpers.swift:23-196` at baseline; grep `final class PhotoImageRequestState` and `final class RequestExecutor`) into WS-10's existing `iOSCleanup/Utilities/PhotoKitRequestState.swift`. Do not create the file; WS-10 did (README contract 8). `VideoFileSizeRequestState` no longer exists: WS-10.5 replaced it with `PhotoKitRequestState<Int64>` in that same file, which `currentVideoURLByteSize` uses, so there is nothing to move for it.
  - Add a timeout seam:
    - `protocol PhotoKitTimeoutScheduling: Sendable { func schedule(after seconds: TimeInterval, _ handler: @escaping @Sendable () -> Void) -> any PhotoKitTimeoutHandle }`
    - `protocol PhotoKitTimeoutHandle: Sendable { func cancel() }`
    - Live `DispatchSourcePhotoKitTimeoutScheduler`: `DispatchSource.makeTimerSource(queue: .global(qos: .utility))`, `schedule(deadline: .now() + seconds, leeway: .milliseconds(250))`, the event handler calls the handler then `timer.cancel()`, `resume()`. The handle's `cancel()` calls `timer.cancel()`, and a cancelled source never fires. Wrap the source in an `@unchecked Sendable` final class.
  - `PhotoImageRequestState` and WS-10's generic `PhotoKitRequestState<Value>` both get `func armTimeout(after:scheduler:onTimeout:)` storing the handle. `resolve`/`complete` and `cancel` call `handle?.cancel()` outside the lock. Because the seam is on the generic type, WS-30's `PhotoKitRequestState<VideoSizeProbe>` (chapter 07) inherits it.
  - `loadImageOutcome` (WS-22) and `currentVideoURLByteSize` (`PHAsset+FileSize.swift:684-716`, on `PhotoKitRequestState<Int64>` since WS-10) arm through `DispatchSourcePhotoKitTimeoutScheduler.shared` instead of `asyncAfter`. The image timeout calls `state.cancel(reason: .timedOut, cancelRequest:)`.
- **Edge cases:**
  - `DispatchWorkItem.cancel()` is **not** enough: a work item scheduled with `asyncAfter` still wakes the queue at its deadline and keeps its captured state until then (`dispatch_block_cancel` semantics).
  - Never deallocate a suspended dispatch source. Always `resume()` before returning the handle.

**WS-24.6 — Coordinator watchdog as a structured child**
- **Why:** tidies the per-asset detached timeout task while keeping the watchdog's guarantee.
- **Change:** in `PhotoScanAnalysisCoordinator.analyze` (256-300):
  - Keep the **operation** in `Task.detached` with `PhotoScanOperationTaskBox`, so a hung, non-cooperative operation can never block the caller.
  - Replace the detached timeout task with `await withTaskGroup(of: Void.self) { group in group.addTask { do { try await watchdogSleep(timeoutNanoseconds) } catch { return }; operationBox.cancel(); await self.releaseSlot(slot); state.resolve(.failed(.timedOut)) }; _ = await state.value(); group.cancelAll() }`, then `return await state.value()`. Sleep through WS-06's injected `watchdogSleep`, never `Task.sleep` directly, so WS-06's `ManualWatchdog` tests keep working. Keep WS-06's DEBUG counters: `releaseSlot` still increments `debugReleaseAttemptCount` on every attempt, and `debugActiveOperationCount` still mirrors the slot count.
  - Keep `PhotoScanSlotReleaseBox` and the cancellation handler.
  - **Never put the operation itself inside the group**: `withTaskGroup` waits for every child, so a non-cooperative operation would defeat the watchdog.
  - Fix the stale comment at 236-239: slots are released on timeout.

**WS-24.7 — Docs and measurements**
- Update CLAUDE.md:
  - `PhotoScanEngine` row: ordered sliding window of `inFlightLimit`, a lookahead of 256, drain in chronological order, `ScanPauseGate`.
  - `PhotoMLBridge`: chained background flushes, with `flushBufferedWrites()` as the durability boundary.
- Record before/after Instruments numbers (photos/s, p50/p99, CPU wakeups while paused) in the PR and in the WS-09 results file. Update WS-08's benchmark (7) `.xcbaseline` if it improved.

### Tests
Simulator unless marked. No wall-clock assertions: slow analyzers use gates. Where a regression would otherwise hang, a safety deadline (5 s) opens the gate, and the test then fails on its count assertion.
- `iOSCleanupTests/OrderedAnalysisWindowTests.swift` *new*:
  - `testNeverExceedsInFlightLimit`.
  - `testDrainIsStrictlyInIndexOrder` (receive in random order).
  - `testLookaheadBoundsPendingResults` (index 0 withheld → `canStart` false after 256 starts).
- `iOSCleanupTests/ScanPauseGateTests.swift` *new*:
  - `testWaitIfPausedReturnsImmediatelyWhenRunning`.
  - `testWaitersResumeOnResume`: two waiters; poll `debugWaiterCount() == 2` with a deadline; `resume` → both return.
  - `testCancellingOneWaiterThrowsWithoutResumingOthers`.
  - `testReasonsAreASetNotACounter`: `pause(.user)` twice, then one `resume(.user)` opens the gate. (WS-25 adds `testGateStaysPausedWhileAnyReasonRemains` once a second reason exists.)
- `iOSCleanupTests/PhotoScanPipelineTests.swift` *new*: engine with a stub provider (64 `ConfigurablePhotoScanTestAsset`s) and an injected analyzer.
  - `testSlowAssetDoesNotStallWindow`: asset 0's analyzer awaits a gate that opens once 16 other analyses have *started* (or at the safety deadline). Assert `startedWhileBlocked >= 16`; lock-step can reach only 7.
  - `testInFlightNeverExceedsLimit`:
    - A `ConcurrencyProbe` (locked `enter`/`exit`, max tracking) ensures the maximum ≤ 8.
    - For non-vacuity, the first 8 calls wait on a barrier that opens only when 8 are concurrently inside.
  - `testPipelinePreservesGroupsAndOrder`:
    - Deterministic fixture with fixed embeddings (WS-08's `TestEmbeddings.base(seed:)` / `offset(_:rmsDistance:seed:)`) and per-call `Task.yield()` loops of seeded-random length.
    - Final group member sets, `keeperAssetID`s and `deleteCandidateIDs` equal a no-delay run.
    - `evaluatedAssetIDs == target set`.
  - `testEveryUpdateCommitsAChronologicalPrefix`: for every update, `evaluatedAssetIDs == Set(sortedTargets.prefix(committedProcessedPhotoCount))`. *Forward note (README contract 15):* WS-53 renames `evaluatedAssetIDs` to the per-update delta `newlyEvaluatedAssetIDs` and rewrites this test to compare the accumulated union; WS-53 owns that change.
  - `testPausedScanStartsNoNewAnalyses`:
    - Pause after 16 analyzer calls (from inside the analyzer via the engine reference).
    - Poll until `pauseGate` has one waiter, record the call count, `await Task.yield()` 100×, and assert the count is unchanged.
    - While parked, assert `await engine.isInAnalysisLoop == true` and that `await engine.inFlightAnalysisCount` equals the analyzer calls that started and have not returned (the WS-27 contract).
    - Resume and assert completion, then `inFlightAnalysisCount == 0` and `isInAnalysisLoop == false`.
- `iOSCleanupTests/PhotoKitRequestStateTests.swift` (created by WS-10; extend it): fake scheduler recording handles.
  - `testResolveCancelsTimeoutHandle`.
  - `testTimeoutAfterResolveDoesNotCancelPhotoKitRequest` (fire the recorded handler after resolve → the cancel closure is never called).
  - `testGenericRequestStateCancelsTimeoutOnComplete` (`PhotoKitRequestState<Int64>`, the type `currentVideoURLByteSize` uses since WS-10).
  - `testLiveSchedulerCancelledTimerNeverFires`: schedule 50 ms, cancel, then an `XCTestExpectation(isInverted: true)` with a 0.2 s timeout. This expectation-based check is the one allowed timing-based test.
- `iOSCleanupTests/PhotoMLBridgeFlushTests.swift` *new* (temp store, WS-08 injectable tuning with `featureFlushCount = 4`):
  - `testFlushBufferedWritesWaitsForInFlightChainedFlush` (buffer 4 → flush queued; `flushBufferedWrites()`; rows == 4).
  - `testChainedFlushesPersistFeaturesBeforePairs` (pairs referencing batch-1 assets in batch 2 are not skipped).
  - `testBackpressureBoundsBufferedRecords` (tuning 8 → buffered + in-flight never exceeds 8 + one batch).
- `iOSCleanupTests/FileScanEngineTests.swift`: `testSlowVideoDoesNotStallOtherMeasurements`. 16 videos; video 0's resolver awaits a gate that opens once the other 15 resolved (safety deadline). Assert `resolvedWhileBlocked == 15`.
- The existing coordinator tests, `testScanUpdateCountIsBoundedByBatchCount`, `testBufferedProgressCarriesDurableCheckpointIntoResumePlan` and `testScanCancellationPropagatesIntoInFlightAssetAnalysis` must pass unchanged.
- **Device-only:** throughput and energy (Device QA).

### Acceptance criteria
- [ ] One task group per run keeps `min(8, remaining)` analyses in flight. A slow asset does not stall later starts (`testSlowAssetDoesNotStallWindow`), and in-flight never exceeds 8.
- [ ] Drain order is chronological. Final groups equal the no-delay run, and every update commits a chronological prefix.
- [ ] The per-batch re-sort is gone.
- [ ] `ScanPauseGate` replaced `isPaused` polling. It is keyed by `ScanPauseReason` (only `.user` so far), and the loop parks only at `drainPoint()`, never inside the drain. `inFlightAnalysisCount` and `isInAnalysisLoop` are exposed on the engine. A paused scan starts no analyses (test), and Instruments shows no periodic PhotoScanEngine wakeups while paused (device).
- [ ] No `asyncAfter` remains in `loadImageOutcome` or `currentVideoURLByteSize`; resolved requests cancel their timer (tests).
- [ ] ML flushes no longer block the drain below 1,024 buffered records, and `flushBufferedWrites()` still persists everything buffered before it (tests).
- [ ] `FileScanEngine` uses the same sliding window (test).
- [ ] On the baseline device, photos/s is at least 2× the WS-09 baseline whenever baseline p99 > 10× p50 (record the numbers; **needs device QA**). WS-08 benchmark (7) does not regress.
- [ ] Zero warnings, full suite green, CLAUDE.md updated.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. **Throughput.** On the WS-09 baseline device and library, run a Deep Clean with Instruments Points of Interest. Record photos/s and p50/p99 `analyze.item`. Confirm `analyze.item` intervals overlap `engine.regroup` and `ml.flush`. Compare with the baseline.
2. **Pause.** Pause a scan for 60 s with the Energy Log and Time Profiler running. There must be no recurring PhotoScanEngine wakeups, and Resume must continue from the same count.
3. **Large Videos.** On a library with some iCloud-only videos, record scan duration before and after.

### Pitfalls and out of scope
- Invariants:
  - Each watchdog slot is released exactly once.
  - Updates stay cumulative with `bufferingNewest(1)`.
  - `flushBufferedWrites()` before every checkpoint is the durability boundary.
  - Drain order stays chronological (README invariant 17).
- Do not change `PhotoScanWorkingSet` (WS-23) or classification. If a test's groups change, the drain order is wrong.
- Do not raise concurrency above 8 or widen the Vision queue; WS-25 owns adaptive limits.
- Thermal/Low Power/memory adaptation is WS-25 (adds `ScanPauseReason.thermal`). WS-27 (chapter 06) adds `.videoPass` and `pause(reason:quiesceTimeout:) -> PhotoScanPauseAck` on top of this drain point. WS-28 adds `.background`; its persisted `PauseReason` (`user`/`backgrounded`/`interrupted`) is a separate `HomeViewModel` type, not a gate reason.
- Progress throttling to 4 Hz is WS-50. Checkpoint cadence is WS-54. Delta updates are WS-53.
- The UI image lane and cancellation queue are WS-52.
- **Reconciliation (README contract 2):** the gate was a `.client` flag in an earlier draft. It is now reason-set based from this workstream, with `ScanPauseReason.user`, and the loop has one named drain point plus the actor-stored `inFlightAnalysisCount`/`isInAnalysisLoop`, so WS-27 can stop top-ups and drain without parking mid-drain. The per-asset `waitWhilePaused()` inside the drain loop is gone.
- **Reconciliation (README contract 8):** `PhotoKitRequestState.swift` and `PhotoKitRequestStateTests.swift` are WS-10's files. This workstream moves `PhotoImageRequestState` in and extends both; `VideoFileSizeRequestState` was already replaced by `PhotoKitRequestState<Int64>` in WS-10.
- **Reconciliation (seams from chapter 02, final):** WS-24.6's structured watchdog child sleeps through WS-06's `watchdogSleep` seam (never `Task.sleep`) and keeps WS-06's DEBUG counters. WS-22.4 changed only the default timeout values. Backpressure lives in WS-08's `PhotoMLWriteBufferTuning`.
- **Reconciliation (README contract 25):** WS-42 renames the `FileScanEngine` API this workstream touches and owns updating the sliding window and `testSlowVideoDoesNotStallOtherMeasurements`.
- **Reconciliation (README contract 15):** `testEveryUpdateCommitsAChronologicalPrefix` reads the cumulative `evaluatedAssetIDs`. WS-53 renames it to the delta `newlyEvaluatedAssetIDs` and rewrites this test to accumulate updates.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| PERF-02 | confirmed | Lock-step verified: 638-676 (the group waits for all 8), 679-688 re-sort, 730 awaited per-asset SQLite, PhotoMLBridge.swift:104-135 inline three-transaction flushes, 902-918 inline regroup, FileScanEngine.swift:163-205. The throughput numbers are estimates, measured in WS-24.0/Device QA. The plan follows the reviewer plus: a 256-item drain lookahead (the reviewer's `pending` map was unbounded behind one slow asset); a serialized flush chain (concurrent detached flushes could write pairs before their features); the per-asset block is WS-23's `PhotoScanWorkingSet`. |
| PERF-14 | partially | (1) Polling confirmed (1001-1007). (2) Uncancelled timers confirmed (SharedHelpers.swift:564, PHAsset+FileSize.swift:709), but the proposed `DispatchWorkItem` fix does not remove the wakeup or the retained closure; the plan uses `DispatchSourceTimer`, whose `cancel()` removes the timer. (3) Overstated: the coordinator's timeout task is cancelled on completion (286), so there is no late wakeup. The plan moves only the sleep into a structured child and keeps the operation detached, because a group racing the operation would wait on non-cooperative operations and defeat the watchdog. |

---

## WS-25 — Resource-aware scanning: thermal, Low Power and memory pressure

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-17, WS-24 | no | `ws/25-resource-aware-scanning` |

**Primary files:** `iOSCleanup/Engines/ScanResourcePolicy.swift` *new*, `iOSCleanup/Engines/ScanResourceMonitor.swift` *new*, `iOSCleanup/Engines/ScanPauseGate.swift`, `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Views/Home/HomeViewModelDependencies.swift`, `iOSCleanup/Views/Home/ScanMemoryPressureResponder.swift` *new*, `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanupTests/ScanResourcePolicyTests.swift` *new*, `iOSCleanupTests/ScanResourceMonitorTests.swift` *new*, `iOSCleanupTests/PhotoScanResourceAdaptationTests.swift` *new*
**Findings covered:** PERF-07 (P2, confirmed)
**Decisions applied:**
- D-SCAN-RESOURCES (first option). Values are tuning constants:
  - nominal/fair: 8 in flight
  - Low Power: 4, 50 ms delay
  - serious: 3, 250 ms delay, "warm" message
  - critical: suspended with a "cool down" message
  - memory warning within 60 s: 2, plus flush and purge

### Goal
A 30–90 minute scan runs cooler and survives memory pressure:
- Warm devices and Low Power Mode lower concurrency with an explanation.
- Critical temperature pauses the scan and resumes it automatically without losing progress.
- Memory warnings shrink concurrency and flush and purge caches.

Classification, keeper choice and deletion semantics are unchanged.

### Current behavior (verified)
- `grep -rn "thermalState\|isLowPowerModeEnabled\|PowerStateDidChange" iOSCleanup/` returns nothing. The only memory-pressure hook is `PhotoImageRepository`'s cache purge (`SharedHelpers.swift:283-291`).
- After WS-24, the engine reads `currentInFlightLimit()` (constant 8, `PhotoScanDefaults.analysisBatchSize`, `PhotoScanEngine.swift:1690`) before every top-up. The Vision queue is 4 wide (`PhotoAssetAnalysisPipeline`, moved by WS-22).
- `ScanPauseGate` (WS-24) is keyed by `ScanPauseReason`; only `.user` exists. The loop parks only at WS-24's `drainPoint()`.
- `HomeViewModel.swift:1707`: `scanActivityMessage = update.statusMessage`, shown by `PhotoDuckShellView.swift:159` and `HomeView.swift:375`. An engine status message reaches the UI without view changes.
- `HomeViewModel.swift:1766-1776`: checkpoints are time-based (`ScanPersistenceTuning.periodicCheckpointInterval = 20`), so extra status-only updates do not multiply checkpoint writes.
- WS-17 provides `PhotoAnalysisCache.purgeMemo()`. WS-14 made analysis intents non-cacheable, so the image repository holds no analysis entries to purge.

### Implementation plan

**WS-25.1 — `ScanResourcePolicy` (pure)**
- **Change:** new file `iOSCleanup/Engines/ScanResourcePolicy.swift`:

```swift
struct ScanResourceState: Sendable, Equatable {
    var thermal: ProcessInfo.ThermalState = .nominal
    var isLowPowerModeEnabled = false
    var lastMemoryWarningAt: Date?
}
struct ScanResourceLimits: Sendable, Equatable {
    let maxInFlight: Int
    let interBatchDelayNanoseconds: UInt64
    let isSuspended: Bool
    let userMessage: String?
}
enum ScanResourcePolicy {
    static let memoryWarningWindow: TimeInterval = 60
    static let warmMessage = "Your iPhone is warm - scanning more slowly"
    static let coolDownMessage = "Paused to let your iPhone cool down"
    static let lowPowerMessage = "Low Power Mode is on. Plug in for faster scanning."
    static func limits(for s: ScanResourceState, now: Date) -> ScanResourceLimits {
        if s.thermal == .critical {
            return .init(maxInFlight: 0, interBatchDelayNanoseconds: 0, isSuspended: true, userMessage: coolDownMessage)
        }
        var inFlight = 8, delay: UInt64 = 0, message: String? = nil
        if s.isLowPowerModeEnabled { inFlight = 4; delay = 50_000_000; message = lowPowerMessage }
        if s.thermal == .serious { inFlight = min(inFlight, 3); delay = max(delay, 250_000_000); message = warmMessage }
        if let warned = s.lastMemoryWarningAt, now.timeIntervalSince(warned) < memoryWarningWindow { inFlight = min(inFlight, 2) }
        return .init(maxInFlight: inFlight, interBatchDelayNanoseconds: delay, isSuspended: false, userMessage: message)
    }
}
```
- **Edge cases:**
  - The most restrictive value wins. The thermal message outranks the Low Power message. A memory warning has no user message.
  - Unknown future `ThermalState` values are treated as nominal (use a `switch` with `@unknown default` if the compiler requires it).

**WS-25.2 — `ScanResourceMonitor` (live, injectable)**
- **Change:** new file `iOSCleanup/Engines/ScanResourceMonitor.swift`.
  - `protocol ScanResourceMonitoring: AnyObject, Sendable { var currentState: ScanResourceState { get }; func stateUpdates() -> AsyncStream<ScanResourceState> }`.
  - `final class ScanResourceMonitor: ScanResourceMonitoring, @unchecked Sendable`:
    - `static let shared = ScanResourceMonitor()`.
    - `init(notificationCenter: NotificationCenter = .default, thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }, isLowPowerModeEnabled: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }, now: @escaping @Sendable () -> Date = Date.init)`.
    - An `NSLock`-protected `state` and `[UUID: AsyncStream<ScanResourceState>.Continuation]`.
    - Observers (queue `nil`): `ProcessInfo.thermalStateDidChangeNotification`, `.NSProcessInfoPowerStateDidChange` and `UIApplication.didReceiveMemoryWarningNotification` (sets `lastMemoryWarningAt = now()`). Each updates the state under the lock and yields the new state to every continuation.
    - `stateUpdates()` registers a continuation (`bufferingNewest(1)`), yields the current state immediately, and removes it in `onTermination`.
  - `HomeViewModelDependencies` (WS-07): add `resourceMonitor: any ScanResourceMonitoring` (`.live` = `ScanResourceMonitor.shared`) and pass it into `makePhotoScanEngine`. WS-29's idle-timer policy reads the same instance.

**WS-25.3 — Engine adaptation**
- **Change:** `PhotoScanEngine.init` gains:
  - `resourceMonitor: any ScanResourceMonitoring = ScanResourceMonitor.shared`
  - `now: @escaping @Sendable () -> Date = Date.init`
  - `sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }`

  Then:
  1. `currentInFlightLimit()` returns `ScanResourcePolicy.limits(for: resourceMonitor.currentState, now: now()).maxInFlight`. That is a lock read per top-up; no actor hop.
  2. Add `case thermal` to `ScanPauseReason` (`ScanPauseGate.swift`, README contract 2).
  3. At the start of `performScan`, start one observation task:

     ```swift
     let observation = Task {
         for await state in resourceMonitor.stateUpdates() {
             let limits = ScanResourcePolicy.limits(for: state, now: now())
             if limits.isSuspended {
                 await pauseGate.pause(.thermal)
                 await mlBridge.flushBufferedWrites()
             } else {
                 await pauseGate.resume(.thermal)
             }
         }
     }
     ```

     Cancel it in a `defer` and on every exit path. It is one task per run, which is bounded.
  4. Status messages:
     - Every regular yield sets `statusMessage = limits.userMessage ?? <today's default text>`.
     - In `waitWhilePaused()` (reached only from WS-24's drain point): if `await pauseGate.isPaused(for: .thermal)` and the last yielded update's message is not the cool-down message, yield `lastYielded` with `statusMessage = ScanResourcePolicy.coolDownMessage` once before waiting. Updates are cumulative, so re-yielding the last update is safe. Keep `lastYielded` as a local in `performScan`.
  5. After each progress yield (every 8 drained assets), `if limits.interBatchDelayNanoseconds > 0 { try await sleep(limits.interBatchDelayNanoseconds) }`. Cancellation propagates.
- **Edge cases:**
  - Thermal suspension is **not** a user pause. The engine never changes `HomeViewModel.isPaused`/`scanState` and never persists `pauseReason .user` (WS-28). The scan stays `.scanning` with the cool-down message.
  - A user pause during suspension still needs a user resume: two reasons, one gate.
  - When the limit drops from 8 to 3, no new analyses start until in-flight falls below 3, so the drop happens within one window.

**WS-25.4 — Memory-pressure responder**
- **Change:**
  - New file `iOSCleanup/Views/Home/ScanMemoryPressureResponder.swift`: `@MainActor final class ScanMemoryPressureResponder { init(monitor: any ScanResourceMonitoring, onMemoryWarning: @escaping @Sendable () async -> Void); func start(); func stop() }`. It iterates `stateUpdates()` and calls `onMemoryWarning` whenever `lastMemoryWarningAt` changes (not for the initial state).
  - `HomeViewModel` owns one instance, created from dependencies with `{ await mlBridge.flushBufferedWrites(); await analysisCache.purgeMemo() }`, and starts it in the bootstrap task.
  - `PhotoImageRepository` already purges its cache on memory warnings, and analysis images are never cached after WS-14, so add nothing there.

**WS-25.5 — Docs**
- Update CLAUDE.md:
  - Add a "Resource-aware scanning" subsection with the policy table.
  - Note that thermal suspension uses `ScanPauseReason.thermal` on `ScanPauseGate` and is never a user pause.
  - Note that `HomeViewModelDependencies.resourceMonitor` is the single monitor.

### Tests
All run in the simulator.
- `iOSCleanupTests/ScanResourcePolicyTests.swift` *new*, table tests:
  - `testNominalAndFairAllowEight`.
  - `testLowPowerAllowsFourWithDelayAndPlugInMessage`.
  - `testSeriousAllowsThreeWithWarmMessage`.
  - `testSeriousAndLowPowerTakeMostRestrictive` (3, 250 ms, warm message).
  - `testCriticalSuspendsWithCoolDownMessage`.
  - `testRecentMemoryWarningCapsAtTwo` (59 s → 2; 61 s → 8).
- `iOSCleanupTests/ScanResourceMonitorTests.swift` *new*: private `NotificationCenter`, closure-backed thermal and low-power values.
  - `testThermalNotificationUpdatesStateAndStream`.
  - `testPowerStateNotificationUpdatesLowPower`.
  - `testMemoryWarningStampsInjectedClock`.
  - `testTerminatedStreamIsRemoved`.
- `iOSCleanupTests/PhotoScanResourceAdaptationTests.swift` *new*: `FakeScanResourceMonitor` (locked state, `set(_:)` yields), an injected no-op `sleep`, and 64 `ConfigurablePhotoScanTestAsset`s.
  - `testSeriousStateCapsConcurrencyAtThree`:
    - The analyzer switches the fake to `.serious` on call 16.
    - A `ConcurrencyProbe` records the maximum concurrency among calls that *start* after call 24 (the window drains first); it must be ≤ 3.
    - A barrier of 8 on the first 8 calls proves the window was 8 before the switch.
    - Updates after the switch carry `ScanResourcePolicy.warmMessage`.
  - `testCriticalSuspendsThenResumesWithIdenticalGroups`:
    - Switch to `.critical` on call 16.
    - Wait (deadline polling over the update stream) for an update with `coolDownMessage`, record the call count, `await Task.yield()` 100×, and assert it is unchanged.
    - `set(.fair)` → the scan completes.
    - Final group member sets and keeper IDs equal a run with the fake held at `.nominal`, and the engine never called `pause()` (no `.user` reason).
  - `testRecentMemoryWarningCapsConcurrencyAtTwo` (injected clock).
  - `testInterBatchDelayIsRequestedUnderLowPower`: the spy `sleep` records 50 ms after each 8-asset yield.
- `iOSCleanupTests/ScanMemoryPressureResponderTests.swift` *new*: `testMemoryWarningFlushesAndPurgesOnce` (spy closure; the initial state does not trigger it).
- `iOSCleanupTests/ScanPauseGateTests.swift`: add `testGateStaysPausedWhileAnyReasonRemains` with `.user` + `.thermal`: resuming either one alone leaves waiters parked, and resuming both releases them.

### Acceptance criteria
- [ ] Under a fake `.serious` state, in-flight analyses drop to ≤3 within one window and updates say "Your iPhone is warm - scanning more slowly".
- [ ] Under `.critical`, the scan starts no analyses, says "Paused to let your iPhone cool down", resumes automatically on `.fair`, and produces identical final groups (tests).
- [ ] Low Power Mode caps at 4 with a 50 ms inter-batch delay and "Plug in for faster scanning" copy. A memory warning caps at 2 for 60 s, flushes ML writes and calls `purgeMemo()`.
- [ ] Thermal suspension never sets `HomeViewModel.isPaused`, `scanState == .paused` or a persisted user pause reason.
- [ ] Classification is unchanged. WS-08 end-to-end tests are green.
- [ ] Zero warnings, CLAUDE.md updated.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. **Serious.** Xcode → Devices and Simulators → device → Device Conditions → Thermal State **Serious**, during a Deep Clean. The activity line shows the warm message, and Instruments Points of Interest shows ≤3 overlapping `analyze.item` intervals.
2. **Critical.** Set **Critical**. The line reads "Paused to let your iPhone cool down", the hero still shows scanning, not a user pause, and the processed count stops. Clear the condition: the scan resumes without a tap, and the processed count continues from where it stopped.
3. **Low Power.** Toggle Low Power Mode on during a scan and confirm the "Plug in for faster scanning" line. Toggle it off: the line clears on the next update.
4. **Memory.** On a 3–4 GB device, run a 30k+ first scan while plugged in. It completes with no jetsam. Record peak memory and thermal state after 30 minutes. The simulator's Debug → Simulate Memory Warning is a smoke test only.

### Pitfalls and out of scope
- The screen idle-timer rule (awake only while thermal ≤ `.fair`) is WS-29 (chapter 06), reading `HomeViewModelDependencies.resourceMonitor`.
- Background pause and `PauseReason` are WS-28. Never map thermal suspension to them.
- Progress throttling is WS-50, and checkpoint cadence per D-SCAN-RESOURCES is WS-54.
- Do not change thresholds, pair classification or keeper ranking. Only concurrency and pacing change.
- D-SCAN-RESOURCES says "between batches". After WS-24 there are no batches, so the delay applies after each 8-asset progress yield.
- Keep the observation task bounded: one per run, cancelled on every exit.
- **Reconciliation (README contract 2):** the thermal gate reason is `ScanPauseReason.thermal` (an earlier draft called it `.resourceSuspension` on a nested `ScanPauseGate.Reason`), and WS-24's user reason is `.user` (formerly `.client`). WS-27 adds `.videoPass` and WS-28 adds `.background`; neither may resume `.thermal`.
- **Forward note (WS-29, chapter 06):** the idle-timer hold reads thermal state from `HomeViewModelDependencies.resourceMonitor` (`currentState.thermal` and `stateUpdates()`). Thermal suspension keeps `scanState == .scanning`, so WS-29's thermal guard, not a paused state, releases the screen hold.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| PERF-07 | confirmed | grep finds no thermal, power or memory observers other than PhotoImageRepository's purge (SharedHelpers.swift:283-291). Concurrency is the constant 8 (PhotoScanEngine.swift:1690, 596-607). Actual heat and throttling behavior is device-dependent (Device QA). The plan follows the reviewer and D-SCAN-RESOURCES. Differences: "purge analysis image entries" is moot after WS-14, because analysis images are never cached and the repository already purges on warnings; `purgeMemo()` and the flush live in a small HomeViewModel-owned responder, since the engine does not own `PhotoAnalysisCache`; the inter-batch delay is per 8 drained assets; the status message is re-yielded on the cumulative last update while suspended. |
