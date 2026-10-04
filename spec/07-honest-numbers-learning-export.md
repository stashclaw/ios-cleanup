# Chapter 07 — Honest numbers, learning hygiene and Export & Delete

> **Milestone(s):** M1 · **Workstreams:** WS-30 – WS-35 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

These six workstreams make every number PhotoDuck shows traceable to a measurement or an explicitly labeled estimate, stop the learning system from silently switching off Keep Best, stop PhotoDuck's own files from inflating the user's backup, and finish Export & Delete so moving media to a drive actually frees iPhone space. WS-30 is the data foundation: bytes plus iCloud locality for photos and videos. WS-31 turns scan results into one pure `ScanOutcomeSummary` that the completion sheet, hero, CTA, empty states and notifications all read. WS-32 uses both for a storage card that matches Settings and an honest "sent to Recently Deleted" ledger. WS-33 and WS-34 are the learning and storage-hygiene pair, and WS-35 completes export. When the chapter is done, a user with iCloud "Optimize iPhone Storage" sees how much of what PhotoDuck found is really on the phone. They never see "clean" after failures, they learn how to empty Recently Deleted, and they can offload verified videos to a drive with one confirmation. The key risk is WS-30. It streams real photo bytes through PhotoKit (bounded, cancellable, never during a scan), and its iCloud signal must be verified on a device before any UI trusts it.

**Order inside the chapter.** WS-30 → WS-31 → WS-32 is a strict chain. WS-33 → WS-34 is a separate chain. WS-35 needs only WS-30, and it may land before WS-31, so it must not use the `CountText`/`ByteText` helpers that WS-31 creates. WS-34 is Track B, so in Track A order WS-35 lands long before it.

---

## WS-30 — Honest sizing and iCloud locality

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-27 | yes | `ws/30-honest-sizing-locality` |

**Primary files:** `iOSCleanup/Utilities/PHAsset+FileSize.swift`, `iOSCleanup/Models/AssetStorageLocation.swift` (*new*), `iOSCleanup/Engines/AssetDeviceFootprintMeasurer.swift` (*new*), `iOSCleanup/Engines/AssetFootprintProbe.swift` (*new, DEBUG only*), `iOSCleanup/Views/Home/ReclaimCandidatePlanner.swift` (*new*), `iOSCleanup/Views/Home/ReclaimMeasurementController.swift` (*new*), `iOSCleanup/Views/Home/DashboardCollectionSummary.swift` (*new, moved*), `iOSCleanup/Models/PhotoGroup.swift`, `iOSCleanup/Models/PhotoGroup+ReclaimSizing.swift` (*new*), `iOSCleanup/Models/LargeFile.swift`, `iOSCleanup/Engines/FileScanEngine.swift`, `iOSCleanup/Views/HomeViewModel.swift` (delegation only), `iOSCleanup/Views/Files/LargeVideoRowViews.swift`, `iOSCleanup/Views/Files/LargeVideoLocalitySummary.swift` (*new*), `iOSCleanup/Views/Files/FileResultsView.swift` (header only), `iOSCleanup/Views/Files/CompressionSourceNotice.swift` (*new*), `iOSCleanup/Views/Files/VideoCompressionView.swift`, `iOSCleanup/Views/Photos/PhotoResultsView.swift` (row label only), `iOSCleanupTests/AssetFootprintTests.swift` (*new*), `iOSCleanupTests/ReclaimSizingTests.swift` (*new*), `iOSCleanupTests/LargeVideoLocalityTests.swift` (*new*)
**Findings covered:** VALUE-02 (P1, confirmed; merged: FILES-03 confirmed), VALUE-10 (P2, confirmed; merged: SCAN-12 partially, FSA-08 confirmed but fixed differently)
**Decisions applied:** D-LIMITED-ACCESS: the new image-size `retain` and the existing video-size `retain` never prune under `.limited`. D-SCOPE: Live Photo *motion* measurement as its own category stays in WS-59. This workstream only includes paired-video bytes in the footprint of assets it already measures.

### Goal
Every byte figure knows two things: whether it is measured or estimated, and whether it lives on this iPhone, only in iCloud, or is not yet known. Videos learn their locality during the video scan. Photos that are reclaim candidates (Keep Best delete candidates, screenshots, blurry) get a measured on-device footprint that covers every resource a deletion removes. Photos that are never measured keep a clearly flagged estimate. Large Videos rows show an "In iCloud" badge, the list header splits on-device from iCloud-only bytes, and compressing an iCloud-only video warns before downloading. The data needed for honest Home totals (`ReclaimSizing` on groups and categories) exists. WS-32 draws the Home storage card from it.

If the diff exceeds about 1,500 lines, ship two PRs from this branch plan. **30a** is WS-30.1–30.5 (video locality). **30b** is WS-30.6–30.11 (photo footprint).

### Current behavior (verified)
- `iOSCleanup/Utilities/PHAsset+FileSize.swift:684-716` `currentVideoURLByteSize(allowNetworkAccess:)` handles `requestAVAsset` with `{ asset, _, _ in … }`. The `info` dictionary, including `PHImageResultIsInCloudKey`, is discarded. Any result that is not an `AVURLAsset` (an iCloud-only original with network off) resolves `nil`, and so does the 5 s watchdog (`asyncAfter(deadline: .now() + 5)`, 709-711). grep finds no `PHImageResultIsInCloudKey` anywhere.
- `…/PHAsset+FileSize.swift:611-658` `representativeFile(allowNetworkAccess:)`: a cached record returns at once (616-627), whatever its age or locality. Only `.video` is measured (628-633). Every other case falls back to `resolveByteCount` → `estimatedByteCount`, flagged `isEstimated`.
- `…/PHAsset+FileSize.swift:181-212` `estimatedByteCount`: `.image` → `max(pixelCount / 3, 0)` (comment: "Roughly 0.33 bytes/pixel"). `.video` → duration × 35/12/6/3 Mbps.
- `…/PHAsset+FileSize.swift:76-91` `AssetResourceSizeCandidate(resource:)` sets `byteCount = nil`. `:99-117` `representative(from:)` picks exactly one resource ("never summed"), so a Live Photo's paired video, RAW alternates and edit originals never count toward a photo's size.
- `…/PHAsset+FileSize.swift:665-676` `estimatedFileSize` returns the front-cache record bytes, else the pixel estimate. Consumers: group reclaim (`Engines/PhotoScanEngine.swift:1474-1484`, `Models/PhotoGroup.swift:262-269`), lifetime stats (`Engines/DeletionManager.swift:395-399`), detail and Duck Mode labels (`PhotoGroupDetailView.swift:122`, `SwipeModeViewModel.swift:317`), export progress (`ExternalPhotoExportService.swift:680,690`), and ML features (`PhotoMLBridge.swift:69`, `SimilarityCoreMLClassifier.swift:450`).
- `…/PHAsset+FileSize.swift:269-286`: `AssetFileSizeProvenance` is `{ measuredCurrentVersion, estimated }` and `AssetFileSizeRecord` is `{ bytes, provenance, savedAt, mediaKind? }`. Neither has any locality.
- `…/PHAsset+FileSize.swift:288-322`: the synchronous front cache `AssetFileSizeCache` holds 2,048 entries and evicts with an O(n) `min(by:)` on every insert over capacity.
- `…/PHAsset+FileSize.swift:325-548` `AssetFileSizeRepository`:
  - `maximumFileBytes = 8 MB` (328) and default `maximumEntryCount: 10_000` (355).
  - Every `store` calls `scheduleWrite()`, which JSON-encodes and atomically writes the whole map (502-540).
  - `evictIfNeeded` does an O(n) scan per removal (493-500).
  - `iOSCleanup/iOSCleanupApp.swift:29` warms every repository entry into the 2,048-entry front cache at launch.
- `iOSCleanup/Engines/FileScanEngine.swift:108-110` default resolver is `asset.representativeFile()` (network off). `:142-145` `retain(localIdentifiers:limitedTo: [.video])` runs whatever the authorization, `.limited` included, which prunes full-library size records (invariant 15). `:176-191` builds a `LargeFile` from bytes and estimated only. `:267-274` `CachedLargeVideoResult` has no locality, and `:277` `schemaVersion = 1`.
- `iOSCleanup/Models/LargeFile.swift:4-31` has no locality field. `:32-34` `formattedSize` is decimal (`countStyle: .file`).
- `iOSCleanup/Views/HomeViewModel.swift:54-117` `DashboardCollectionSummary` sums every `LargeFile.byteSize` (113-115) and every group `reclaimableBytes`. `:352-354` `reclaimableBytes = largeFileBytes + reclaimablePhotoBytes`, which feeds "Found by PhotoDuck" inside the iPhone "used" bar (`HomeView.swift:740-744, 780`).
- `iOSCleanup/Views/Files/VideoCompressionView.swift:262-289` `runCompression` loads the AVAsset with `isNetworkAccessAllowed = true` (415) and shows "Downloading from iCloud · N%". Nothing warns before Start. `VideoCompressionEngine.resolveOriginalBytes` then measures the downloaded local file, so an iCloud-only video compresses after a full download and saves a new *local* copy.
- `iOSCleanup/Models/PhotoGroup.swift:154-156`: `reclaimableBytes` is the passed value or `estimateReclaimableBytes`, and 0 when delete candidates are not exposed. `Engines/PhotoAnalysisCache.swift:352,450` persists and rehydrates `reclaimableBytes` in `CachedPhotoGroup`.
- `iOSCleanup/Views/Photos/PhotoResultsView.swift:710-712` row label is `"Save \(ByteCountFormatter…)"` with no estimate marker. `Views/Files/FileResultsView.swift:1513-1523` rows prefix `~` for estimated videos. WS-10 moves `FileRow`/`LargeVideoGridCard` to `LargeVideoRowViews.swift` and the request-state classes into a generic `PhotoKitRequestState<Value>`.

### Implementation plan

**WS-30.1 — Device verification probe (verify-first, DEBUG only)**
- **Why:** The locality model rests on two device behaviors the simulator cannot show:
  - with network access off, `PHAssetResourceManager.requestData` fails with `networkAccessRequired` for iCloud-only resources and streams local ones;
  - `requestAVAsset(.current, network off)` returns `nil` plus `PHImageResultIsInCloudKey == true` for offloaded videos.

  If either is wrong, every "on this iPhone" figure is wrong.
- **Change:**
  1. Implement `LiveAssetResourceFootprintSource` from WS-30.7 first. The probe exercises it.
  2. New file `iOSCleanup/Engines/AssetFootprintProbe.swift`, wrapped entirely in `#if DEBUG`. Add `enum AssetFootprintProbe { static func run() async -> String }`. It fetches the 15 newest and 15 oldest images plus the 5 newest and 5 oldest videos, then:
     - runs `LiveAssetResourceFootprintSource.measureResources(of:)` on each image and tallies `AssetResourceKind` × outcome (`local`, `iCloudOnly`, `unavailable(domain:code)`);
     - calls `requestAVAsset` (`.current`, network off) on each video and tallies `AVURLAsset` / `nil + inCloud` / `nil, no key`.

     Return a plain-text histogram with **no identifiers, filenames or dates** (invariant 26).
  3. Add `Button("Probe iCloud locality")` inside the existing `#if DEBUG` block of the Similar tab menu (`Views/PhotoDuckShellView.swift` ~254). Show the report in the existing alert used for the ML export.
  4. Add the device step below to `docs/DEVICE_QA.md`. The owner runs it on an iPhone with iCloud Photos plus Optimize iPhone Storage and records the result in `docs/qa-runs/<date>-ws30-locality.md`.
  5. **Gate.** Continue past WS-30.5 only if both hold:
     - (a) iCloud-only image resources fail with `PHPhotosError.networkAccessRequired`. If another domain or code is observed, add it to `ResourceMeasurement.Outcome.classify` (WS-30.7) and note it in the PR.
     - (b) Local resources stream more than 0 bytes.

     If the video tally shows `nil` with no in-cloud key for offloaded videos, change WS-30.3's probe to the fallback described there.
- **Edge cases:**
  - The probe must run with network access **off**. Never set `isNetworkAccessAllowed = true` in it.
  - Run it on the main actor's Task only for the UI hop. The measurements themselves run off-main.

**WS-30.2 — Locality and footprint model**
- **Why:** Nothing can say "on this iPhone" or "estimated" until the model carries it. Every new field must be optional so existing JSON decodes.
- **Change:** New file `iOSCleanup/Models/AssetStorageLocation.swift`:
  ```swift
  enum AssetStorageLocation: String, Codable, Sendable {
      case onDevice, partial, iCloudOnly, unknown
  }

  /// Everything a deletion of this asset removes, as measured with network access off.
  struct AssetDeviceFootprint: Codable, Equatable, Sendable {
      var deviceBytes: Int64               // streamed local resources (measured)
      var iCloudOnlyEstimatedBytes: Int64  // typed estimate of resources that need the network
      var unavailableEstimatedBytes: Int64 // typed estimate of resources that failed otherwise
      var location: AssetStorageLocation
      var measuredAt: Date
      var totalBytes: Int64 { deviceBytes &+ iCloudOnlyEstimatedBytes &+ unavailableEstimatedBytes } // use saturating add helper
      var isFullyMeasured: Bool { iCloudOnlyEstimatedBytes == 0 && unavailableEstimatedBytes == 0 }
      var reclaimSizing: ReclaimSizing {
          ReclaimSizing(deviceBytes: deviceBytes, iCloudOnlyBytes: iCloudOnlyEstimatedBytes,
                        unknownLocalityBytes: unavailableEstimatedBytes)
      }
  }

  /// Bytes a set of items would free, split by where they live.
  struct ReclaimSizing: Equatable, Sendable {
      var deviceBytes: Int64 = 0           // measured, on this iPhone
      var iCloudOnlyBytes: Int64 = 0       // estimated, frees iCloud storage only
      var unknownLocalityBytes: Int64 = 0  // estimated, not measured yet
      static let zero = ReclaimSizing()
      static func unmeasured(_ bytes: Int64) -> ReclaimSizing { .init(unknownLocalityBytes: max(bytes, 0)) }
      var totalBytes: Int64 { /* saturating sum of the three */ }
      var isEstimated: Bool { iCloudOnlyBytes > 0 || unknownLocalityBytes > 0 }
      var isEntirelyICloudOnly: Bool { iCloudOnlyBytes > 0 && deviceBytes == 0 && unknownLocalityBytes == 0 }
      static func + (lhs: Self, rhs: Self) -> Self  // saturating per field
  }
  ```
  - In `PHAsset+FileSize.swift`, add `case measuredDeviceFootprint` to `AssetFileSizeProvenance`. Add three `var` optionals to `AssetFileSizeRecord`: `storageLocation: AssetStorageLocation?`, `locationCheckedAt: Date?` and `footprint: AssetDeviceFootprint?`. Synthesized `Codable` uses `decodeIfPresent` for optionals, so legacy files decode with `nil`. Keep `AssetFileSizeRepository.schemaVersion = 1`.
  - `estimatedFileSize` becomes `cached.footprint?.totalBytes ?? cached.bytes`, with the pixel fallback unchanged. Add `var cachedStorageLocation: AssetStorageLocation` (front cache only; `.unknown` when absent) for row badges.
  - **One locality type.** `AssetStorageLocation` (property name `storageLocation` everywhere, including `LargeFile`) is the only locality type. Do not add `AssetLocalAvailability`/`localAvailability` or any second enum. `.partial` exists only for photo footprints (WS-30.7). The video probe and `LargeFile.storageLocation` only ever produce `.onDevice`, `.iCloudOnly` or `.unknown`, and consumers that switch over the enum (WS-42's `VideoInventorySummary.add(location:)`, WS-43's `sourceIsLocal`) treat `.partial` as on-device.
- **Edge cases:** The new enum case cannot be decoded by an older build. Downgrades are unsupported, so this is fine. Say so in the PR.

**WS-30.3 — Video locality probe**
- **Why:** An iCloud-only video's info dictionary says so, but the code throws it away and guesses a bitrate size that is then counted as iPhone space (FILES-03).
- **Change (`PHAsset+FileSize.swift`):**
  - Replace `currentVideoURLByteSize` with a per-version probe, `func videoSizeProbe(version: PHVideoRequestOptionsVersion = .current, allowNetworkAccess: Bool = false) async -> VideoSizeProbe`, where `enum VideoSizeProbe: Equatable, Sendable { case measured(Int64), composition, iCloudOnly, unavailable }`. Make it `internal` (not `private`): WS-42's `VideoSizeMeasurement` builds its per-version `request` closure on it (retrying `.original` after a `.composition`), and WS-43/WS-44 call it with `allowNetworkAccess: false` from `VideoCompressionView` when a file's locality is `.unknown`.
  - Add the pure mapper `static func resolve(urlAssetFileSize: Int?, deliveredNonFileAsset: Bool, isInCloud: Bool?) -> VideoSizeProbe`: file size > 0 → `.measured`; else `isInCloud == true` → `.iCloudOnly`; else `deliveredNonFileAsset` (PhotoKit returned an `AVAsset` that is not an `AVURLAsset`, for example a slo-mo `AVComposition`) → `.composition`; else `.unavailable`. The request handler becomes `{ asset, _, info in … }` and passes `(info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue`.
  - Use WS-10's `PhotoKitRequestState<VideoSizeProbe>` (in `Utilities/PhotoKitRequestState.swift`). The 5 s timeout resolves `.unavailable`.
  - **Fallback if the WS-30.1 video tally showed `nil` with no in-cloud key for offloaded videos:** stream the representative video resource via `requestData` with network off and cancel after the first chunk. One chunk means `.measured` needs the URL path, so combine: `nil` asset plus a first chunk means on device (size still unknown, stays estimated). `networkAccessRequired` means `.iCloudOnly`.
- `PHAssetRepresentativeFile` gains `let storageLocation: AssetStorageLocation`. Add an explicit init with default `.unknown` so existing call sites and tests compile.
- `representativeFile(allowNetworkAccess:revalidateLocality: Bool = false)`:
  - A cached record is returned as-is only when `!revalidateLocality` and `record.locationCheckedAt` is newer than `AssetLocalityPolicy.recheckInterval` (7 days, a tuning constant in `AssetStorageLocation.swift`).
  - Otherwise, for videos, re-probe with `videoSizeProbe(version: .current, allowNetworkAccess:)`. `.measured` stores `.measuredCurrentVersion` with `storageLocation: .onDevice`. `.iCloudOnly` stores `.estimated` with `.iCloudOnly`. `.unavailable` and `.composition` keep any previous bytes, set `.unknown`, and still stamp `locationCheckedAt` (WS-42 later retries `.composition` with `.original`).
  - Store through `AssetFileSizeRepository.store` (single persistence path).
- `FileScanEngine`:
  - Add `scan(revalidateLocality: Bool = false, onUpdate:)`. `FileRepresentativeResolver` becomes `@Sendable (_ asset: PHAsset, _ revalidateLocality: Bool) async -> PHAssetRepresentativeFile`; update the injected test resolvers to `{ asset, _ in … }`. Do not add a `FileScanOptions` struct.
  - Only the explicit user refresh passes `true`: `scanFiles(trigger: .userExplicit)` (WS-27; the Files "Refresh", "Check Videos Now" and "Scan Videos Again" actions), threaded through `LargeVideoScanController.run`. Every other `FileScanTrigger` (tab visit, automatic freshness, pre-pass, post-photo pass, insertions, deferred replay) passes `false`.
  - **Forward note (L25):** WS-42 renames this flag to `remeasureEstimates` (`scan(remeasureEstimates:onUpdate:)`, `representativeFile(allowNetworkAccess:remeasureEstimates:)`, resolver `(asset, remeasureEstimates)`), makes `scan` return `FileScanResult` and renames `FileScanUpdate.largeFiles` to `retainedVideos`. It is still one flag with the same trigger, and WS-42's `RepresentativeCachePolicy.usesCachedRecord` must keep this workstream's `locationCheckedAt`/`AssetLocalityPolicy.recheckInterval` rule. WS-42 owns updating this workstream's call sites and tests.
- **Edge cases:**
  - A local-but-edited video whose render is missing may return `nil` without the key. Map it to `.unavailable`, never `.iCloudOnly`.
  - Keep the probe's network flag `false` for scans (invariant 11).

**WS-30.4 — Locality on `LargeFile` and the video cache**
- **Change:**
  - `LargeFile` gains `let storageLocation: AssetStorageLocation`, an init parameter defaulting to `.unknown`. `FileScanEngine` passes `representative.storageLocation`.
  - `CachedLargeVideoResult` gains `let storageLocation: AssetStorageLocation?`. Synthesized `Codable` treats it as optional; `nil` restores as `.unknown`. `LargeVideoResultCache.save`/`restoreFiles` copy it. Keep `CachedLargeVideoSnapshot.schemaVersion = 1`; WS-42's v2 must carry this field.
  - Gate the existing `retain(… limitedTo: [.video])` in `FileScanEngine.largePhotoAssets` on the authorization being `.authorized`: call WS-20's pure static `LibraryPersistenceGate.persistsLibraryDerivedState(status)` with the status the engine already reads at scan start. Under `.limited`, skip the prune (D-LIMITED-ACCESS).
- **Edge cases:** WS-27 serialized `LargeVideoResultCache` writes behind a revision guard. Do not change that locking; only add the field.

**WS-30.5 — Large Videos locality UI and the compression notice** *(end of PR 30a)*
- **Why:** The user cannot tell which videos free iPhone space, and compressing an iCloud-only video silently downloads gigabytes and adds a local copy.
- **Change:**
  - New `iOSCleanup/Views/Files/LargeVideoLocalitySummary.swift`: `struct LargeVideoLocalitySummary: Equatable { let onDeviceBytes, iCloudOnlyBytes, unknownBytes: Int64; let iCloudOnlyCount: Int; static func make(files: [LargeFile]) -> Self }`.
    - `.onDevice` and `.partial` count as device bytes (for videos, `.partial` never occurs; treat it as on-device).
    - `.iCloudOnly` counts as iCloud-only and `.unknown` as unknown.
    - Also add `enum LargeVideoLocalityFilter: String, CaseIterable { case all, onThisIPhone }` with `func includes(_ file: LargeFile) -> Bool` (`onThisIPhone` keeps `.onDevice` and `.partial` only).
  - `LargeVideoRowViews.swift` (`FileRow` and `LargeVideoGridCard`): when `file.storageLocation == .iCloudOnly`, show a small badge `Label("In iCloud", systemImage: "icloud")` in `.duckLabel` with `Color.textSecondary`. Change the estimated-size prefix from `~` to `≈`. Add an accessibility label, "Stored only in iCloud; deleting frees iCloud storage".
  - `FileResultsView` list header (one line only; keep the file from growing): `"On this iPhone: \(onDevice) · Only in iCloud: \(iCloud)"`, formatted with `Int64.formattedBytes` and shown only when `iCloudOnlyBytes > 0`. Add a two-option `Picker`/segmented chip bound to `@State var localityFilter: LargeVideoLocalityFilter = .all`. Apply the filter to `files` before the existing organizer, so sorting stays largest-first. `DECISION (owner may override): Large Videos keeps largest-first order; locality is surfaced by badge, header and an "On this iPhone" filter instead of re-sorting on-device first.`
  - New `iOSCleanup/Views/Files/CompressionSourceNotice.swift`: `enum CompressionSourceNotice { static func message(for file: LargeFile) -> String? }`. It returns `nil` unless the file is `.iCloudOnly`, and otherwise: "This video is stored in iCloud. Compressing downloads about \(size) first (this can use cellular data) and saves the smaller copy on this iPhone. It frees iCloud storage, not iPhone storage."
  - In `VideoCompressionView`, when the notice is non-nil, `compressButton` sets `@State showICloudSourceNotice = true` instead of calling `startCompression()`. A `.confirmationDialog` offers "Download and Compress" (calls `startCompression()`) and "Cancel". Functional change only; no visual redesign (Files/compression awaits the design handoff).
- **Edge cases:** Unknown locality shows no badge and no notice. Never claim a video is in iCloud without the probe saying so.

**WS-30.6 — Typed estimates for resources the measurer cannot stream**
- **Why:** A flat 0.33 B/px overstates HEIC by about 2× and understates RAW by about 4× (VALUE-10/FSA-08).
- **Change (`AssetResourceSizePolicy`, `PHAsset+FileSize.swift`):** add
  ```swift
  import UniformTypeIdentifiers
  static let livePhotoMotionEstimateBytes: Int64 = 2_000_000
  static func bytesPerPixel(typeIdentifier: String?) -> Double {
      guard let id = typeIdentifier, let type = UTType(id) else { return 1.0 / 3.0 } // legacy default, unchanged
      if type.conforms(to: .rawImage) { return 1.5 }
      if type.conforms(to: .heic) || type.conforms(to: .heif) { return 0.17 }
      if type.conforms(to: .jpeg) { return 0.30 }
      if type.conforms(to: .png) { return 0.55 }
      return 1.0 / 3.0
  }
  static func estimatedResourceBytes(kind: AssetResourceKind, typeIdentifier: String?,
                                     pixelWidth: Int, pixelHeight: Int, duration: TimeInterval) -> Int64
  ```
  - Photo kinds (`photo`, `fullSizePhoto`, `alternatePhoto`, `adjustmentBasePhoto`) → pixels × `bytesPerPixel`.
  - Paired-video kinds (`pairedVideo`, `fullSizePairedVideo`, `adjustmentBasePairedVideo`) → `livePhotoMotionEstimateBytes`.
  - Video kinds → the existing bitrate estimate.
  - `adjustmentData`, `audio`, `other` → 0.
- **Edge cases:** The synchronous `estimatedFileSize` fallback for never-measured assets stays at pixel/3. It has no resource list, and every such figure is shown as estimated and "unknown locality". Say this in the PR; it is a deliberate difference from FSA-08.

**WS-30.7 — `AssetDeviceFootprintMeasurer`**
- **Why:** This is the only public-API way to know a photo's on-device bytes. It must never use the private `fileSize` KVC on `PHAssetResource`.
- **Change:** new file `iOSCleanup/Engines/AssetDeviceFootprintMeasurer.swift` (use `@preconcurrency import Photos`, as `FileScanEngine` does).
  ```swift
  struct ResourceMeasurement: Equatable, Sendable {
      enum Outcome: Equatable, Sendable {
          case local(bytes: Int64), iCloudOnly, unavailable
          static func classify(_ error: Error) -> Outcome {
              if let e = error as? PHPhotosError, e.code == .networkAccessRequired { return .iCloudOnly }
              return .unavailable // add any extra "not local" domain/code observed in WS-30.1 here
          }
      }
      let kind: AssetResourceKind
      let typeIdentifier: String?
      let outcome: Outcome
  }
  protocol AssetResourceFootprintSource: Sendable {
      func measureResources(of asset: PHAsset) async -> [ResourceMeasurement]
  }
  enum AssetFootprintMath {
      static func combine(_ m: [ResourceMeasurement], pixelWidth: Int, pixelHeight: Int,
                          duration: TimeInterval, measuredAt: Date) -> AssetDeviceFootprint
  }
  struct FootprintMeasurementResult: Sendable {
      let key: AssetFileSizeCacheKey; let mediaKind: AssetMediaKind; let footprint: AssetDeviceFootprint
  }
  actor AssetDeviceFootprintMeasurer {
      static let maximumConcurrentAssets = 2
      init(source: any AssetResourceFootprintSource = LiveAssetResourceFootprintSource(),
           now: @escaping @Sendable () -> Date = { Date() })
      func measure(_ assets: [PHAsset], onResult: @escaping @Sendable (FootprintMeasurementResult) async -> Void) async
  }
  ```
  - `combine` rules:
    - `local` adds to `deviceBytes`.
    - `iCloudOnly` and `unavailable` add `estimatedResourceBytes(…)` to their buckets.
    - `location`: no resources → `.unknown`; ≥1 local and 0 iCloud-only → `.onDevice` (unavailable bytes stay "unknown"); ≥1 local and ≥1 iCloud-only → `.partial`; 0 local and ≥1 iCloud-only → `.iCloudOnly`; otherwise `.unknown`.
  - `measure` keeps at most 2 assets in flight: a `withTaskGroup` sliding window with `addTask(priority: .utility)`. Before each new task it checks `Task.isCancelled`, and on cancellation it `cancelAll()`s and drains. `measureOne` is `nonisolated`.
  - `LiveAssetResourceFootprintSource.measureResources(of:)`:
    - enumerate `PHAssetResource.assetResources(for: asset)` and stream each resource sequentially;
    - use `PHAssetResourceRequestOptions` with `isNetworkAccessAllowed = false`;
    - the `dataReceivedHandler` adds `data.count` to a lock-protected counter and never retains `data`;
    - completion is `nil` → `.local(bytes: total)`, error → `classify`;
    - wrap the request in `withTaskCancellationHandler`, calling `cancelDataRequest(_:)`, plus a 30 s per-resource watchdog that resolves `.unavailable`;
    - reuse WS-10's `PhotoKitRequestState<ResourceMeasurement.Outcome>` for resume-exactly-once.
- **Edge cases:**
  - Sum **every** listed resource (photo, fullSizePhoto, alternatePhoto, paired and fullSize paired video, adjustment data, adjustment bases, `photoProxy` → `.other`), because deletion removes all of them.
  - `measureResources` must return promptly when cancelled. A single 75 MB ProRAW file streams in well under a second locally; the watchdog is only a backstop.

**WS-30.8 — Repository: library-scale capacity and batch APIs**
- **Why:** Records for a 60k library must not evict each other. The measurer must not trigger a full-file rewrite per result.
- **Change (`AssetFileSizeRepository`):**
  - Set `static let defaultMaximumEntryCount = 60_000` (the init default) and `maximumFileBytes = 32 * 1_024 * 1_024`.
  - `evictIfNeeded()`: when `entries.count > maximumEntryCount`, sort by `accessOrdinal` once and drop the oldest overflow. This replaces the per-removal `min(by:)` loop. WS-54 later swaps in WS-52's O(1) `LRUCache`; do **not** touch the 2,048 front cache here.
  - `func records(for keys: [AssetFileSizeCacheKey]) async -> [AssetFileSizeCacheKey: AssetFileSizeRecord]`: batch read that does not store into the front cache.
  - `func mergeFootprints(_ results: [FootprintMeasurementResult]) async`:
    - an existing record keeps its `bytes`/`provenance` (video representative size) and gains `footprint`, `storageLocation`, `locationCheckedAt`;
    - when no record exists, write `AssetFileSizeRecord(bytes: max(footprint.totalBytes, 1), provenance: footprint.isFullyMeasured ? .measuredDeviceFootprint : .estimated, …)`;
    - one eviction pass, then **one** `scheduleWrite()` per call.
  - `func warmMemoryCache(for keys: [AssetFileSizeCacheKey]) async` stores only these keys into the front cache.
- **Edge cases:** Keep `retain(localIdentifiers:limitedTo:)` semantics. A record with a `nil` `mediaKind` is never evicted by a scoped retain (existing comment at 406-409).

**WS-30.9 — `ReclaimSizing` on `PhotoGroup`**
- **Why:** Group rows, Auto-clean totals and Home need device versus iCloud bytes per group. Every rebuild must still go through `PhotoGroup.init` (invariant 1).
- **Change:**
  - `Models/PhotoGroup.swift`: add a stored `let reclaimSizing: ReclaimSizing` and an init parameter `reclaimSizing: ReclaimSizing? = nil`. Inside `init`:
    - when `!shouldExposeDeleteCandidates`, `reclaimSizing = .zero` and `reclaimableBytes = 0` (existing rule);
    - otherwise `reclaimSizing = reclaimSizing ?? .unmeasured(resolvedBytes)` and `reclaimableBytes = self.reclaimSizing.totalBytes`, where `resolvedBytes` is the existing `reclaimableBytes ?? estimateReclaimableBytes(…)`.

    The invariant `reclaimableBytes == reclaimSizing.totalBytes` always holds.
  - New `Models/PhotoGroup+ReclaimSizing.swift`: `func replacingReclaimSizing(_ sizing: ReclaimSizing) -> PhotoGroup`. It calls the full `PhotoGroup.init`, passing every stored field unchanged (`id`, `assets`, `similarity`, `reason`, `groupType`, `groupConfidence`, `reviewState`, `recommendedAction`, `keeperAssetID`, `deleteCandidateIDs`, `bestShotPhotoId`, `groupReasonsSummary`, `blockerFlags`, `scoreBreakdown`, `preferenceQueuePriority`, `preferenceAdjustmentReasons`, `captureDateRange`, `candidates`) plus `reclaimSizing: sizing`. Later stored fields are added to this call by the workstream that introduces them: WS-40's `autoCleanPolicy` and WS-63's `pairEvidence`.
  - Audit every `PhotoGroup(` rebuild site with `grep -rn "PhotoGroup(" iOSCleanup`: WS-12 `applyingUserKeptIDs`, WS-21 `PhotoResultPruner`, `CachedPhotoGroup.makeGroup`. Where `deleteCandidateIDs` are unchanged, pass the old `reclaimSizing` through. Where they change, pass `nil` so the controller recomputes.
  - `CachedPhotoGroup` is **not** changed. The size repository is the single persistence path for measurements, so WS-16's `AnalysisSnapshotBuilder` golden test stays byte-identical.
- **Edge cases:** A group whose keeper vanished is downgraded by `init` and gets `.zero`. Never compute sizing for review-only groups.

**WS-30.10 — Candidate planning and the measurement controller**
- **Why:** `requestData` reads every byte, so measurement must be bounded, prioritized, resumable across launches, and never compete with a scan (invariant 16's spirit: no parallel heavy PhotoKit work).
- **Change:**
  - New `Views/Home/ReclaimCandidatePlanner.swift` (pure):
    ```swift
    enum ReclaimCandidatePlanner {
        static let maximumAssetsPerPass = 3_000   // tuning constant
        static func plan(prioritized: [PHAsset], groups: [PhotoGroup], screenshots: [PHAsset], blurry: [PHAsset],
                         existing: [String: AssetDeviceFootprint], now: Date,
                         recheckInterval: TimeInterval = AssetLocalityPolicy.recheckInterval,
                         cap: Int = maximumAssetsPerPass) -> [PHAsset]
    }
    ```
    Order:
    1. `prioritized` (the category the user just opened);
    2. delete candidates of `isAutoCleanEligible` groups, groups sorted by `reclaimableBytes` descending then `id.uuidString`, candidates resolved **by ID** from `group.assets`;
    3. delete candidates of any other group with non-empty `deleteCandidateIDs`;
    4. screenshots;
    5. blurry.

    Dedupe by `localIdentifier`. Skip assets whose `existing` footprint is younger than `recheckInterval`. Truncate to `cap`.
  - New `Views/Home/ReclaimMeasurementController.swift`, `@MainActor final class ReclaimMeasurementController`:
    - `@Published private(set) var footprintsByAssetID: [String: AssetDeviceFootprint]`, `@Published private(set) var isMeasuring`.
    - `func refresh(groups:screenshots:blurry:prioritized:canMeasure:libraryImageIDsForRetention:)` is single-flight: a new call cancels the running pass. Steps:
      - (a) load `records(for:)` for every delete-candidate, screenshot and blurry key into `footprintsByAssetID` and report them at once (no PhotoKit reads);
      - (b) if `canMeasure`, run the planner and the measurer;
      - (c) forward UI updates in batches of 64 results or every 1 s;
      - (d) persist via `mergeFootprints` in batches of 512 results or every 30 s and at pass end;
      - (e) at pass end, `warmMemoryCache(for:)` the top 2,048 planned keys so `estimatedFileSize` reads measured bytes for the likeliest deletions.
    - `func cancel()`.
    - `func sizing(forDeleteCandidatesOf group: PhotoGroup) -> ReclaimSizing` and `func sizing(for assets: [PHAsset]) -> ReclaimSizing`. For missing footprints, use `.unmeasured(asset.estimatedFileSize)`.
    - `var onFootprintsChanged: (() -> Void)?`.
    - `libraryImageIDsForRetention` is non-nil only when WS-20's `LibraryPersistenceGate.persistsLibraryDerivedState(status)` is true and the completed run covered the full library. When set, call `AssetFileSizeRepository.retain(localIdentifiers:limitedTo: [.image])` once before measuring.
  - `HomeViewModel` (delegation only):
    - own the controller, built from a new `footprintSource` entry in WS-07's `HomeViewModelDependencies` (live default; tests inject a stub);
    - set `canMeasure = !isPhotoRunActive && !isVideoPassRunning && scenePhase == .active` (WS-27/WS-28 names);
    - call `refresh` after the completion barrier of a photo run is published (do **not** move the barrier; invariant 13), after cached-analysis hydration, and on `.active` when the last pass is older than 1 h;
    - call `cancel()` when a photo run or video pass starts and on `.background`.
  - Expose `func prioritizeFootprints(for assets: [PHAsset])`. `HomeView` calls it from `.task` on the Screenshots and Blurry tile destinations (one line each).
  - `onFootprintsChanged` → `PhotoResultsStore` (WS-16) applies, in one batch, `group.replacingReclaimSizing(controller.sizing(forDeleteCandidatesOf: group))` for every group whose sizing changed, then rebuilds the summary once. Skip the apply while `isPhotoRunActive`; the next refresh reapplies. Throttle applies to ≤ 1 per second during a pass.
- **Edge cases:**
  - Never measure during a scan run or the video pass, while backgrounded, or while WS-25's `dependencies.resourceMonitor.currentState.thermal` is `.serious` or `.critical`.
  - Limited access may measure (records are per asset and prune nothing) but must not retain.
  - This workstream extends WS-21's `HomeViewModel.applyConfirmedDeletion(assetIDs: Set<String>)`, which receives `DeletionManager.confirmedDeletions` once per PhotoKit-confirmed commit, to remove those IDs from `footprintsByAssetID`.
  - Do **not** schedule a snapshot write for sizing changes.

**WS-30.11 — Summary sizing and row labels**
- **Change:**
  - Move `DashboardCollectionSummary` (currently `HomeViewModel.swift:54-117`; WS-16 may have moved it beside `PhotoResultsStore`) into `iOSCleanup/Views/Home/DashboardCollectionSummary.swift` unchanged, then extend it:
    - `make(groups:screenshotAssets:blurryAssets:largeFiles:footprints: [String: AssetDeviceFootprint] = [:])`;
    - new fields `photoReclaimSizing` (sum of group `reclaimSizing`), `screenshotSizing` and `blurrySizing` (footprint else `.unmeasured(estimatedFileSize)`), and `largeVideoSizing` (`.onDevice`/`.partial` → device, `.iCloudOnly` → iCloud, `.unknown` → unknown);
    - keep `reclaimablePhotoBytes` and `largeFileBytes` with today's meaning (WS-32 switches consumers).
    - **Forward note (L25):** `largeFiles:` here is `LargeVideoScanController.largeFiles`. After WS-42 it is derived from `retainedVideos` as the non-recording videos at the user's threshold, and screen recordings get their own `CleanupOpportunity.Kind.screenRecordings`. `largeVideoSizing`, `largeFileBytes` and every consumer in WS-31/WS-32 keep meaning "large videos at the chosen threshold". WS-42 updates these call sites and tests.
  - `PhotoResultsView` row label (`actionLabel`, ~710-712):
    - `group.reclaimSizing.isEntirelyICloudOnly` → `"Frees ≈\(bytes) in iCloud"`;
    - else prefix `≈` when `isEstimated`;
    - keep `ByteCountFormatter` here (WS-31 swaps formatters).
  - The Auto-clean confirmation total (~477) prefixes `≈` when any group `isEstimated`.
- **Edge cases:** Review-only groups show no bytes (unchanged).

### Tests
All run in the simulator unless marked. Add every new test file to `project.pbxproj` (file reference, group and Sources phase).
- `iOSCleanupTests/AssetFootprintTests.swift`:
  - `testLegacyFileSizeRecordDecodesWithUnknownLocality`: decode `{"bytes":5,"provenance":"estimated","savedAt":0}`; the new fields are nil.
  - `testEstimatedFileSizePrefersFootprintTotal`: through `AssetFileSizeRepository(fileURL: temp)`, store a record with footprint then `warmMemoryCache(for:)`; use a `TestPhotoAsset` (WS-03) with a matching key.
  - `testCombineCountsEveryLocalResource`: photo 2,000,000 + pairedVideo 2,500,000 + adjustmentData 3,000 → device 4,503,000, `.onDevice`, fully measured.
  - `testCombineICloudOnlyResourceUsesTypedEstimate`: HEIC photo iCloud-only at 4032×3024 → device 0, iCloud ≈ 0.17 × pixels, `.iCloudOnly`.
  - `testCombineMixedLocalAndICloudIsPartial`.
  - `testCombineAllUnavailableIsUnknown`.
  - `testClassifyNetworkAccessRequiredIsICloudOnly` / `testClassifyOtherErrorIsUnavailable`.
  - `testBytesPerPixelTable`: heic, jpeg, png, `com.adobe.raw-image`, nil.
  - `testEstimatedResourceBytesPerKind`.
  - `testMeasurerNeverExceedsTwoConcurrentAssets`: a stub source that records max in-flight count using an actor counter and suspends on `AsyncStream` gates (no sleeps).
  - `testMeasurerStopsOnCancellation`: cancel the parent task after the first result; the stub records no further starts beyond the in-flight 2.
  - `testMergeFootprintKeepsVideoRepresentativeBytes`.
  - `testMergeFootprintWritesOncePerBatch`: DEBUG counter `writeCount` added to the repository.
  - `testRepositoryDefaultCapacityIsLibraryScale`: `defaultMaximumEntryCount == 60_000`.
  - `testRepositoryKeeps12kEntriesWithoutEviction`: `mergeFootprints` with 12,000 synthetic keys; `debugEntryCount() == 12_000`.
  - `testBatchEvictionDropsOldestOverflow`: capacity 10, insert 15; the 5 lowest ordinals are gone.
  - `testVideoProbeMapping` (arguments are `urlAssetFileSize`, `deliveredNonFileAsset`, `isInCloud`): `(10, false, nil) == .measured(10)`, `(nil, false, true) == .iCloudOnly`, `(nil, true, true) == .iCloudOnly`, `(nil, true, nil) == .composition`, `(nil, false, false) == .unavailable`, `(nil, false, nil) == .unavailable`.
- `iOSCleanupTests/LargeVideoLocalityTests.swift`:
  - `testLegacyCachedLargeVideoResultRestoresUnknownLocality`: JSON without the field.
  - `testFileScanCarriesProbeLocality`: an injected resolver returns `.iCloudOnly`; the resulting `LargeFile.storageLocation == .iCloudOnly`.
  - `testForcedScanRequestsLocalityRevalidation`: the resolver records its second argument; `scan(onUpdate:)` gives false and `scan(revalidateLocality: true, onUpdate:)` gives true.
  - `testLimitedAccessScanDoesNotPruneSizeRecords`: temp repository plus a stub asset provider under `.limited`.
  - `testLocalitySummarySplitsBytes`.
  - `testOnThisIPhoneFilterExcludesICloudOnly`.
  - `testCompressionNoticeOnlyForICloudOnly`.
- `iOSCleanupTests/ReclaimSizingTests.swift`:
  - `testReclaimSizingSaturatingSumAndEstimateFlag`.
  - `testReviewOnlyGroupHasZeroSizing`: a `visuallySimilar` group → `.zero` and `reclaimableBytes == 0`.
  - `testReplacingReclaimSizingPreservesEveryOtherField`: compare every stored property and `isAutoCleanEligible` before and after, for an eligible group and a downgraded group.
  - `testReclaimableBytesEqualsSizingTotal`.
  - `testPlannerOrdersEligibleCandidatesFirstThenScreenshotsThenBlurry`.
  - `testPlannerResolvesCandidatesByIDNotPosition`: `assets` shuffled relative to `deleteCandidateIDs`.
  - `testPlannerSkipsFreshFootprintsAndRechecksStaleOnes`: an injected `now`.
  - `testPlannerRespectsCap`.
  - `testSummarySplitsDeviceICloudUnknownBytes`: groups with measured, iCloud-only and unmeasured candidates, plus large files of each locality.
  - `testControllerAppliesStoredRecordsWithoutMeasuringWhenCanMeasureIsFalse`: a stub source that fails the test if called.
- **Device only:** see Device QA. The simulator has no iCloud-only assets.

### Acceptance criteria
- [ ] WS-30.1 probe result is recorded in `docs/qa-runs/` and the classify table matches it (PR links the run).
- [ ] No code uses private KVC on `PHAssetResource` (`grep -rn "value(forKey" iOSCleanup` shows no resource access).
- [ ] Legacy `asset-file-sizes-v1.json` and `large-video-results.json` decode, and restored items show `.unknown` locality (tests).
- [ ] Offloaded videos show "In iCloud", and the Large Videos header splits on-device and iCloud-only bytes (device QA).
- [ ] Compressing an iCloud-only video shows the notice before any download (device QA plus `testCompressionNoticeOnlyForICloudOnly`).
- [ ] Group reclaim bytes come from measured footprints when available, with `reclaimableBytes == reclaimSizing.totalBytes` (tests). Estimated values render with `≈`.
- [ ] No measurement runs during a photo run, a video pass, or while backgrounded (unit test with a stub source plus a device os_log check).
- [ ] Under `.limited`, neither video nor image size records are pruned (test).
- [ ] The `AnalysisSnapshotBuilder` golden test from WS-16 is unchanged. The full suite is green with zero new warnings.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. **Locality probe (verify-first).** iPhone with iCloud Photos and "Optimize iPhone Storage" on, and an older library where some originals are offloaded (confirm in airplane mode that opening an old photo shows a download spinner). DEBUG build → Similar tab menu → "Probe iCloud locality". Record the histogram. Expected: old images show `iCloudOnly`, recent ones `local`, and offloaded videos report nil with the in-cloud key.
2. Run a Deep Clean and wait for the measurement pass (os_log category `ReclaimMeasurement`: start and finish, with counts only). Record the duration for up to 3,000 assets and the thermal state before and after.
3. Files tab: offloaded videos carry "In iCloud". The header shows both totals. "On this iPhone" hides them.
4. Tap Compress on an "In iCloud" video. The notice appears. Cancel, and confirm no download started (no progress, no network in Instruments).
5. Start a scan while a measurement pass runs. The pass stops, per the log.

### Pitfalls and out of scope
- Do not raise the 2,048 front-cache capacity or change `warmMemoryCache()` for the whole repository. WS-54 does that after WS-52's O(1) LRU. Do not add time-based write coalescing to the repository either; WS-54 owns PERF-13. The batch sizes here are the interim bound.
- `estimatedFileSize` now includes paired video and other resources for measured assets. That changes `PhotoMLBridge` training features (DEBUG-only after WS-33; skew documented there) and export progress estimates (harmless).
- Home storage card, stat tiles and "found" wording are WS-32. The completion sheet and CTA are WS-31. Live Photo motion as its own opportunity is WS-59, which reuses this measurer. Slo-mo remeasurement and threshold chips are WS-42.
- Never infer delete candidates from `assets` order in the planner. Measurement order is not destructive, but resolve by ID anyway so reviewers do not have to reason about it.
- Keep `@preconcurrency import Photos` usage consistent. Do not mark `PHAsset` `@unchecked Sendable`.
- **Reconciliation:**
  - One locality type, `AssetStorageLocation`/`storageLocation` (chapter 09 issue). Chapter 09's contract table spells the probe case `inCloudOnly`; the canonical case is `VideoSizeProbe.iCloudOnly`.
  - The video probe is per-version (`videoSizeProbe(version:allowNetworkAccess:)`) and gains `.composition`, so WS-42's `VideoSizeMeasurement` and WS-43/WS-44's network-off check in `VideoCompressionView` can call it directly.
  - L25: the resolver takes one `Bool` flag (no `FileScanOptions`) so WS-42's rename to `(asset, remeasureEstimates)` is mechanical. Forward notes on `largeFiles` are in WS-30.3 and WS-30.11.
  - The forced refresh is `scanFiles(trigger: .userExplicit)`, because WS-27 replaced `scanFiles(force:)`. The Limited-access prune gate calls `LibraryPersistenceGate.persistsLibraryDerivedState` (WS-20's actual name). Footprint removal extends WS-21's `applyConfirmedDeletion(assetIDs:)` (lead item, chapters 03–04 final).
  - Later stored `PhotoGroup` fields must be added to `replacingReclaimSizing` by the workstream that introduces them: WS-40's `autoCleanPolicy` and WS-63's `pairEvidence`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| VALUE-02 | confirmed | `currentVideoURLByteSize` drops `info` (PHAsset+FileSize.swift:697). Photos are always pixel estimates. `LargeFile` has no locality. The storage bar counts every byte as iPhone space. Plan follows the fix, with one change: the Home explainer card and bar split move to WS-32. |
| FILES-03 | confirmed | Same evidence. Compression downloads with network on (VideoCompressionView.swift:415), and after download `resolveOriginalBytes` measures the local file, so compression proceeds and adds a local copy. Plan adds a notice rather than blocking. Uses a filter instead of sorting on-device first (DECISION above). |
| VALUE-10 | confirmed | Image estimate is `pixelCount / 3` (192-194). The representative policy excludes paired video and RAW. The repository caps at 10,000 (355). Uses one `requestData` measurer as specified. The typed fallback applies to resources the measurer cannot stream; never-measured assets keep 0.33 B/px, flagged as estimated. |
| SCAN-12 | partially | Real, but overstated for Live Photos: the pixel/3 overestimate of the still roughly offsets the missing motion clip. HEIC stills are about 2× high. Plan adopts the measurer (same idea as its `PhotoReclaimSizer`), named `AssetDeviceFootprintMeasurer`. |
| FSA-08 | confirmed | Correct about estimates everywhere. Its `requestContentEditingInput` measurement is **not** used: it misses paired video and adjustment resources. `requestData` streaming covers them. |

---

## WS-31 — Scan outcome single source of truth and completion alerts

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-15, WS-22, WS-26, WS-27, WS-28, WS-29, WS-30 | no | `ws/31-scan-outcome-summary` |

**Primary files:** `iOSCleanup/Utilities/CountText.swift` (*new*), `iOSCleanup/Views/Home/ScanOutcomeSummary.swift` (*new*), `iOSCleanup/Views/Home/HomeDashboardPresentation.swift` (*new*), `iOSCleanup/Views/Home/HomeCTAAction.swift` (*new*; WS-45 extends it), `iOSCleanup/Views/Home/HomeRouteDestinationView.swift` (*new*), `iOSCleanup/Views/Home/ScanOrigin.swift` (WS-26; `AutomaticScanNotice.message` only), `iOSCleanup/Views/Home/CompletionOverlay.swift`, `iOSCleanup/Views/Home/CompletionNotificationContent.swift` (*new*), `iOSCleanup/Views/Home/CompletionNotificationService.swift`, `iOSCleanup/Views/Photos/ResultsEmptyContext.swift` (*new*), `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/HomeViewModel.swift` (delegation only), `iOSCleanup/Views/Photos/PhotoResultsView.swift`, `iOSCleanup/Views/Photos/PhotoCategoryReviewView.swift`, `iOSCleanup/Views/EmptyStateView.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/iOSCleanupApp.swift`, `iOSCleanupTests/ScanOutcomeSummaryTests.swift` (*new*), `iOSCleanupTests/HomeDashboardPresentationTests.swift` (*new*), `iOSCleanupTests/CompletionNotificationContentTests.swift` (*new*), `iOSCleanupTests/ResultsEmptyContextTests.swift` (*new*)
**Findings covered:** UI-06 (P1, confirmed; merged: VALUE-04 confirmed, BUILD-11 partially), UI-07 (P1, confirmed), STATE-13 (P3, confirmed)
**Decisions applied:** D-HVM-DECOMP: delivers STATE-12 phase 1. Presentation copy moves into pure types; HomeViewModel keeps its view API and only delegates.

### Goal
One pure `ScanOutcomeSummary` decides what a finished scan means, and five surfaces derive from it: the completion sheet, the Home hero, the Home CTA, the empty states and the completion notification. After failures, nothing says "clean" or "Cleanup complete". Counts are pluralized, and bytes use one format ("0 MB", never "Zero KB"). The primary action routes to the biggest real opportunity, never to a forced full rescan. Tapping an alert opens the screen its text describes, including from a cold launch.

### Current behavior (verified)
- `iOSCleanup/Views/HomeView.swift:1024-1084` `CompletionOverlay`:
  - value: `lastCompletedGroupsCount > 0 ? "\(n) groups ready" : "\(photoReviewCategoryCount) photos to review"` (1036-1038), never pluralized;
  - detail: `ByteCountFormatter.string(…)` → "Zero KB" (1039), while the StatPill uses `formattedBytesStat` → "0 MB" (1055);
  - primary: `photoGroups.isEmpty ? "Scan Again" : "Review Now"`, where Scan Again calls `restartPhotoScan()` (1063-1070);
  - never mentions unanalyzed photos.

  WS-10 moves it to `Views/Home/CompletionOverlay.swift`.
- `HomeView.swift:125-138`: the sheet's `onDismiss` opens results only through `openReviewAfterCompletion`. `HomeView.swift:87` is a plain `NavigationStack` with no path. Tiles push via destination closures (616-700).
- `HomeView.swift:343-395` `ctaTitle`/`ctaSubtitle`: completed with 0 groups shows "Scan again · No photo issues found · runs a fresh photo scan" (364, 391) even when screenshots or large videos exist. `:426-449` `handleCTAAction` falls through to `restartPhotoScan()` (446). WS-26 deletes `restartPhotoScan()` and routes these call sites (and the sheet's "Scan Again") through `startPhotoScan(from:)`; WS-26/WS-27 also change the 0-group subtitle and add the video pre-pass copy.
- `iOSCleanup/Views/HomeViewModel.swift:616-640` `heroStatusLabel` returns "Cleanup complete" for any `.completedResultsAvailable` (638). `:642-661` `heroPrimaryMetricValue` shows "0 photo findings" (655). `:681-716` `heroDetailText` falls back to "Your library looks clean." (712). `:356-358` `reclaimableFormatted` uses `ByteCountFormatter`.
- `HomeViewModel.swift:1209-1225` notification copy is branched inline. `:2315-2321` `maybeScheduleNotification` always sends target `.reviewResults`. `:2593-2595` `enum CleanupReviewTarget { case reviewResults }`. WS-15 moves this into `CompletionNotificationService` verbatim.
- `HomeViewModel.swift:318-331` bootstrap runs `await scanNewPhotosIfNeeded()` **before** `refreshPersistenceHealth()` and `refreshNotificationAuthorization()`. Authorization is never re-read on `.active` (`updateScenePhase`, 1530-1580).
- `iOSCleanup/iOSCleanupApp.swift:56-84`: `CleanupNotificationRouter.didReceive` sets `pendingTarget` via `DispatchQueue.main.async`. `Views/PhotoDuckShellView.swift:88-95` consumes it only in `.onChange`, so a value set before the shell exists (cold launch, onboarding) is never handled. It always selects `.similar`.
- `Views/Photos/PhotoResultsView.swift:70-75`: an empty `visibleGroups` shows `EmptyStateView(title: "Your library looks clean", …)` with the default `.celebration` style (`Views/EmptyStateView.swift:16`: "Clean outcome" badge plus "Ready"), whatever the scan state.
- `PhotoDuckShellView.swift:5-23` `SimilarPhotosPrimaryAction.resolve(scanState:hasResults:)`. `:193-204` `.review` opens Duck Mode even when no group is eligible. `:240-248` "Review Results" is always enabled. `:457-492` the dock "Review" button is always enabled. `:149` `heroMetricText` uses `ByteCountFormatter`.
- `HomeView.swift:1165-1170` `PhotoCategoryReviewView` empty state uses the celebration style ("Nothing to review"). WS-10 moves it to `Views/Photos/PhotoCategoryReviewView.swift`.
- No pluralization helper exists (`grep -rn plural iOSCleanup` is empty). `Int64.formattedBytesStat` (`Utilities/SharedHelpers.swift:534-536`) maps 0 → "0 MB".

### Implementation plan

**WS-31.1 — `CountText` and `ByteText`**
- **Why:** RT-2's "1 photos" and "Zero KB" vs "0 MB" come from ad-hoc strings.
- **Change:** new file `iOSCleanup/Utilities/CountText.swift`:
  ```swift
  enum CountText {
      static func items(_ n: Int, _ singular: String, _ plural: String) -> String {
          "\(n.formatted()) \(n == 1 ? singular : plural)"
      }
      static func photos(_ n: Int) -> String { items(n, "photo", "photos") }
      static func groups(_ n: Int) -> String { items(n, "group", "groups") }
      static func videos(_ n: Int) -> String { items(n, "video", "videos") }
      static func screenshots(_ n: Int) -> String { items(n, "screenshot", "screenshots") }
  }
  enum ByteText {
      /// Decimal (Settings-style) sizes; zero is "0 MB", never "Zero KB".
      static func stat(_ bytes: Int64) -> String {
          bytes <= 0 ? "0 MB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
      }
      static func approximate(_ sizing: ReclaimSizing) -> String {
          (sizing.isEstimated ? "≈" : "") + stat(sizing.totalBytes)
      }
      static func approximate(_ bytes: Int64, isEstimated: Bool) -> String { (isEstimated ? "≈" : "") + stat(bytes) }
  }
  ```
  Make `Int64.formattedBytesStat` return `ByteText.stat(self)` so existing callers agree. Use these helpers in every string this workstream touches. WS-56 sweeps the rest and adds the global lint rule.
- **Edge cases:** Negative bytes render "0 MB". `n.formatted()` localizes grouping ("1,800").

**WS-31.2 — `ScanOutcomeSummary`**
- **Why:** Five surfaces branch independently today and contradict each other (RT-2). VALUE-04: screenshots and large videos never count as "found".
- **Change:** new file `iOSCleanup/Views/Home/ScanOutcomeSummary.swift`:
  ```swift
  enum HomeRoute: Hashable, Sendable {
      case reviewGroups                               // results sheet (existing)
      case screenshots, blurry, largeVideos, similarReviewOnly   // pushed in Home's NavigationStack
      case retryUnanalyzed                            // WS-22's retry confirmation, not a push
      var isPushed: Bool { … }
  }
  struct CleanupOpportunity: Equatable, Sendable, Identifiable {
      enum Kind: String, Sendable { case largeVideos, duplicates, screenshots, blurry, similarReviewOnly }
      let kind: Kind; let itemCount: Int; let sizing: ReclaimSizing
      var isReviewOnly: Bool { kind == .similarReviewOnly }
      var route: HomeRoute { … }            // duplicates → .reviewGroups, etc.
      var id: Kind { kind }
  }
  struct ScanOutcomeInputs: Equatable, Sendable {
      var analyzedCount, unanalyzedCount, unanalyzedICloudCount, unanalyzedDeviceFailureCount: Int // WS-22
      var duplicateGroupCount, eligibleGroupCount, visuallySimilarGroupCount: Int
      var duplicateSizing: ReclaimSizing                           // WS-30 photoReclaimSizing
      var screenshotCount: Int; var screenshotSizing: ReclaimSizing
      var blurryCount: Int; var blurrySizing: ReclaimSizing
      var largeVideoCount: Int; var largeVideoSizing: ReclaimSizing
      var sessionDeletedItemCount: Int
  }
  struct ScanOutcomeSummary: Equatable, Sendable {
      enum Kind: Equatable, Sendable { case findings, nothingFound, incomplete(unanalyzed: Int), analysisFailed(unanalyzed: Int) }
      enum PrimaryAction: Equatable, Sendable { case route(HomeRoute), done }
      let kind: Kind; let opportunities: [CleanupOpportunity]
      let title: String; let headline: String; let detail: String
      let heroStatus: String; let primaryAction: PrimaryAction; let showsScanAgainLink: Bool
      static func make(_ inputs: ScanOutcomeInputs) -> ScanOutcomeSummary
  }
  ```
  Rules, all pure:
  - **Opportunities.** One per kind with `itemCount > 0`: duplicates use group counts, similar uses review-only group count with `.zero` sizing, others use item counts. Sort order: `isReviewOnly` ascending, then `sizing.deviceBytes` descending, `sizing.totalBytes` descending, `itemCount` descending, then `Kind.rawValue`.
  - **`kind`.** In precedence order:
    - `analyzed == 0 && unanalyzed > 0` → `.analysisFailed`;
    - `unanalyzed > 0` → `.incomplete`;
    - any opportunity → `.findings`;
    - else `.nothingFound`.
  - **`title`.** "Scan complete" for findings and nothingFound, "Scan incomplete", or "Couldn't analyze your photos".
  - **`heroStatus`.** Failed → "Couldn't analyze photos". Incomplete → "Scan incomplete". Otherwise "Cleanup complete" only if `sessionDeletedItemCount > 0`, else "Scan complete".
  - **`headline`.**
    - Non-review-only device bytes > 0 → "≈X on this iPhone you could free".
    - Else if iCloud bytes > 0 → "≈X in iCloud you could free".
    - Else if any opportunity → "\(top opportunity count text) to review".
    - nothingFound → "Nothing to clean up".
    - analysisFailed with no opportunities → "Photos couldn't be analyzed".
  - **`detail`.**
    - Failed or incomplete: "\(CountText.photos(unanalyzed)) couldn't be analyzed", plus " — most are stored only in iCloud." when `unanalyzedICloudCount * 2 > unanalyzed`, else " on this iPhone.". Then one line per opportunity.
    - nothingFound: "PhotoDuck checked \(CountText.photos(analyzed)) and found nothing to review."
    - Opportunity lines use `CountText` and `ByteText.approximate`, e.g. "1,800 screenshots · ≈1.9 GB".
  - **`primaryAction`.** The first non-review-only opportunity → `.route(its route)`. Else `unanalyzed > 0` → `.route(.retryUnanalyzed)`. Else a review-only opportunity → `.route(.similarReviewOnly)`. Else `.done`.
  - **`showsScanAgainLink`.** True for findings and nothingFound. The link runs WS-26's incremental user-initiated entry point, `viewModel.startPhotoScan(from: .completionSheetScanAgain)` (`refreshPhotoScan()` is private to `HomeViewModel`).
  - `HomeViewModel` builds the inputs from `dashboardSummary` (WS-30 sizing), WS-22's pass-throughs (`unanalyzedPhotoCount`, `unanalyzedICloudCount`, `unanalyzedDeviceFailureCount`) and the session deletion counter. Expose `var scanOutcomeInputs: ScanOutcomeInputs` and `var scanOutcome: ScanOutcomeSummary { .make(scanOutcomeInputs) }`.
  - `sessionDeletedItemCount`: WS-31 extends WS-21's `applyConfirmedDeletion(assetIDs: Set<String>)`, which receives `DeletionManager.confirmedDeletions` exactly once per PhotoKit-confirmed commit, and increments by `assetIDs.count` (equal to the receipt's `itemCount`). Keep it in memory only. Reset it in `scanPhotos` when `origin == .userInitiated` (WS-26's `ScanOrigin`).
  - `CleanupOpportunity.Kind` (nested) is the only name for the opportunity kind (L10). Do not add a top-level `CleanupOpportunityKind` type or typealias. Later workstreams add cases additively, with tests: WS-42 adds `.screenRecordings` (plus a `HomeRoute` that opens Files with a kind filter), WS-59 adds `.livePhotoMotion`/`.largePhotos` and WS-62 adds `.duplicateVideos` (all supplementary).
- **Edge cases:**
  - `unanalyzed > 0` never yields "clean" or "Nothing to clean up" (invariant 11).
  - Blurry items are deletable by user selection, so they are not review-only.
  - Large videos come from WS-27's fresh video results even while the video pass runs. Treat an in-progress video pass as zero videos rather than guessing.
  - **Forward note (L25):** `largeVideoCount`/`largeVideoSizing` read `largeFiles`. After WS-42 that is the non-recording list at the user's threshold (derived from `retainedVideos`), and recordings arrive through `.screenRecordings`. WS-42 updates this builder and its tests.

**WS-31.3 — `HomeDashboardPresentation` (STATE-12 phase 1)**
- **Why:** Hero and CTA copy is untestable computed state in a 2,640-line class (BUILD-11).
- **Change:** new file `iOSCleanup/Views/Home/HomeCTAAction.swift` (L26: WS-31 introduces the enum and its resolver; WS-45 extends this file and never creates a second enum):
  ```swift
  enum HomeCTAAction: Equatable { case openSettings, startScan, pause, resume, refreshScan, route(HomeRoute), none
      static func resolve(_ inputs: HomeDashboardInputs) -> HomeCTAAction   // today's handleCTAAction branching, moved verbatim
  }
  ```
  and new file `iOSCleanup/Views/Home/HomeDashboardPresentation.swift`:
  ```swift
  struct HomeDashboardInputs: Equatable { /* heroState, outcome: ScanOutcomeSummary, progress snapshot fields,
      isCompletingActiveScan, isPhotoRunActive (WS-28), isVideoPrePassRunning (WS-27.6), isVideoPassRunning and
      videoPassProgressLabel (WS-27.2), pauseReason (WS-28.3), autoResumeBlockedMessage (WS-28.4), resultsFreshnessState,
      lastCompletedAt, cleanupMode, hasPartialResults, scanActivityMessage, fileScanStatusMessage, … */ }
  struct HomeDashboardPresentation: Equatable {
      let heroStatusLabel, heroPrimaryMetricValue, heroPrimaryMetricTitle, heroDetailText: String
      let ctaTitle, ctaSubtitle: String; let ctaAction: HomeCTAAction; let ctaIsEnabled: Bool
      static func make(_ inputs: HomeDashboardInputs) -> HomeDashboardPresentation   // ctaAction = HomeCTAAction.resolve(inputs)
  }
  ```
  - First move the current branches (`heroStatusLabel`, `heroPrimaryMetricValue`, `heroPrimaryMetricTitle`, `heroDetailText`, `scanProgressLabel`, `scanRateLabel`, `progressPercentLabel`, `findingsSoFarLabel`, and whatever WS-07/WS-15/WS-22/WS-26–WS-29 left of lines ~616-822) plus HomeView's `ctaTitle`/`ctaSubtitle`/`handleCTAAction` branching and its `.disabled(…)` conditions (into `ctaIsEnabled`) into `make` and `HomeCTAAction.resolve` **verbatim**. Commit that alone, with the suite green.
  - **The verbatim move carries chapter 06's interim copy unchanged.** `testNonCompletedStatesMatchLegacyCopy` pins each string:
    - WS-27.6 videos-first pre-pass (`isVideoPrePassRunning`): hero detail "Checking large videos first · \(videoPassProgressLabel)"; CTA "Checking large videos…" with subtitle "Photos start right after"; `ctaIsEnabled == false` (the button is disabled, so its action is unreachable).
    - WS-27.2: while `isCompletingActiveScan`, CTA "Finishing photo scan…" with subtitle "Saving the completed photo results". While `isVideoPassRunning`, the CTA subtitle is `videoPassProgressLabel` ("Checking large videos… x/y", or "Checking large videos…" while the total is 0), and the completed hero detail keys on `isVideoPassRunning`.
    - WS-26.4: the 0-group CTA subtitle "No photo issues found · checks new photos" (replaced below only in the `.completedResultsAvailable` branch).
    - WS-28.4: `.deepCleanPaused` hero detail is `autoResumeBlockedMessage` ("PhotoDuck stopped unexpectedly. Tap Continue to try again.") when it is set.
    - The scan footer stays in `HomeView`: WS-29.5's `ScanFooterPresentation.message(for: backgroundContinuationState)`, and "Notify me" only when `ScanFooterPresentation.showsNotifyMe(for:)` is true. Do not move or re-gate it.
  - Then change only the `.completedResultsAvailable` branches:
    - status = `outcome.heroStatus`;
    - metric = the top opportunity as `ByteText.approximate(sizing)` when its total bytes > 0, else its count text; "All clear" for nothingFound; "\(CountText.photos(n)) not analyzed" for analysisFailed with no opportunity;
    - detail = `outcome.headline`;
    - CTA title and subtitle from `outcome.primaryAction`: `.route(.reviewGroups)` → "Review \(CountText.groups(n)) ready"; `.route(.largeVideos)` → "Free up ≈X", subtitle "Start with Large Videos · \(CountText.videos(n))"; `.route(.screenshots)` → "Review \(CountText.screenshots(n))"; `.route(.retryUnanalyzed)` → "Retry \(CountText.photos(n))" with WS-22's reason subtitle; `.done` → "Check for new photos", subtitle "Scans only photos added since the last scan", action `.refreshScan`.
  - Any `ByteCountFormatter` in moved code becomes `ByteText.stat`.
  - `HomeViewModel` keeps its property names as one-line forwards to `dashboardPresentation` (view API unchanged). `HomeView.ctaTitle`/`ctaSubtitle` read `viewModel.dashboardPresentation`, the button uses `.disabled(!presentation.ctaIsEnabled)`, and `handleCTAAction` switches on `ctaAction`:
    - `.refreshScan` → `viewModel.startPhotoScan(from: .homePrimaryCTA)` (WS-26's incremental user-initiated entry; `refreshPhotoScan()` is private);
    - `.route(r)` → `open(r)` (WS-31.4).
  - `heroState` itself stays in `HomeViewModel`; it is an input.
  - `AutomaticScanNotice.message` (WS-26.1, `ScanOrigin.swift`) switches to `CountText.photos`/`CountText.groups`, as WS-26 anticipated. The toast text is otherwise unchanged.
- **Edge cases:** No presentation action may force a full rescan. `restartPhotoScan()` no longer exists (WS-26 deleted it); only the confirmed gear action `startPhotoScan(from: .gearRescanConfirmed)` runs `rescanEntireLibrary()`. WS-45 (chapter 09) later extends `HomeCTAAction` and `resolve` in `HomeCTAAction.swift` (L26): it keeps the `isVideoPrePassRunning` case (a disabled "Checking large videos…" CTA, carried here through `ctaIsEnabled`), adds `isVideoPassRunning` → review results, maps the outcome's opportunities, and removes the CTA pause. It must extend this enum, not create a second one.

**WS-31.4 — Completion sheet from the summary and `HomeRoute` navigation**
- **Change:**
  - `CompletionOverlay` takes `let outcome: ScanOutcomeSummary` and `let onAction: (ScanOutcomeSummary.PrimaryAction) -> Void`. Render with existing components only (scan-celebration visuals await the design handoff):
    - `PrimaryMetricCard(title: outcome.title, value: outcome.headline, detail: outcome.detail, …)`;
    - one compact `DuckCard` row per opportunity (count text, `ByteText.approximate`, a "Review" text button → `onAction(.route(opp.route))`);
    - `DuckPrimaryButton` titled from `primaryAction` ("Review now", "Retry N photos", "Done");
    - when `showsScanAgainLink`, a text button "Check for new photos" that calls `onAction(.done)` and then `viewModel.startPhotoScan(from: .completionSheetScanAgain)` (WS-26's entry point, replacing the sheet's "Scan Again" label);
    - `DuckOutlineButton("Back to Library")`.

    Remove the two `StatPill`s (they duplicated the headline). The sheet's only scan action is `.completionSheetScanAgain`, which is incremental.
  - `HomeView` replaces `openReviewAfterCompletion` with `@State var pendingCompletionAction: ScanOutcomeSummary.PrimaryAction?`, applied in the sheet's `onDismiss` through `open(_ route: HomeRoute)`:
    - `.reviewGroups` → `showReviewResults = true`;
    - `.retryUnanalyzed` → the same choice the Home banner makes after WS-22: `UnanalyzedPhotosBannerModel.make(total:reasonCounts:)` gives `.downloadAndRescan` (`showICloudScanConfirmation = true`) or `.retryOnDevice` (`viewModel.retryUnanalyzedOnDevice()`);
    - pushed routes → `homePath.append(route)`.

    Change `NavigationStack {` to `NavigationStack(path: $homePath)` with `@State private var homePath: [HomeRoute] = []`, and add `.navigationDestination(for: HomeRoute.self) { HomeRouteDestinationView(route: $0, viewModel: viewModel) }`.
  - New `Views/Home/HomeRouteDestinationView.swift` builds the same destinations the tiles use: `PhotoCategoryReviewView` for screenshots and blurry, `FileResultsView` for large videos, `PhotoResultsView(groups: visuallySimilarPhotoGroups, emptyContext:)` for similarReviewOnly, and environment objects as the tiles pass them. For non-pushed routes, `assertionFailure` in DEBUG and `EmptyView()`.
  - The existing destination-closure tiles keep working alongside the typed path.
- **Edge cases:** When the sheet presents is WS-26/WS-27's decision (user-initiated runs, token). Do not change it.

**WS-31.5 — Honest empty states and Similar-tab actions (UI-07)**
- **Change:**
  - New `Views/Photos/ResultsEmptyContext.swift`:
    ```swift
    enum ResultsEmptyContext: Equatable {
        case noFindings, scanNotRun, scanInProgress, incomplete(unanalyzed: Int), accessNeeded, cleanedEverything
        static func resolve(scanState: HomeViewModel.ScanState, authorization: PHAuthorizationStatus,
                            unanalyzedCount: Int, hasCompletedScan: Bool) -> ResultsEmptyContext
        var style: EmptyStateView.Style      // .celebration only for .noFindings and .cleanedEverything
        var title: String; var message: String; var actionTitle: String?
    }
    ```
    `resolve` precedence:
    1. `.denied`/`.restricted` → `.accessNeeded` ("Photos access is off", action "Open Settings");
    2. scanning or paused → `.scanInProgress` (neutral, "Results appear as the scan runs");
    3. `unanalyzed > 0` → `.incomplete` (neutral, "\(CountText.photos(n)) couldn't be analyzed", action "Retry");
    4. `!hasCompletedScan` → `.scanNotRun` (neutral, action "Start scan");
    5. otherwise `.noFindings` (celebration, "No similar photos found").
  - `PhotoResultsView` gains `var emptyContext: ResultsEmptyContext = .noFindings` and `var onEmptyAction: ((ResultsEmptyContext) -> Void)? = nil`. When `visibleGroups.isEmpty`:
    - with `!hiddenGroupIDs.isEmpty`, use `.cleanedEverything` (celebration, "You cleared this list");
    - otherwise use `emptyContext` with `EmptyStateView(title:icon:message:style:actionTitle:action:)`.
  - `HomeViewModel.resultsEmptyContext` (a one-line forward) feeds every caller: the HomeView results sheet, the Duplicates and Similar tiles, the shell sheet and `HomeRouteDestinationView`. Actions map to `openPhotoAccessSettings()`, the retry route and `startDeepClean()`.
  - `PhotoCategoryReviewView` empty state passes `style: .neutral`.
  - `SimilarPhotosPrimaryAction.resolve(scanState:hasResults:hasEligibleGroups: Bool = true, accessDenied: Bool = false)` adds `case openSettings, reviewList`:
    - `accessDenied` → `.openSettings` (first);
    - scanning/paused as today;
    - `hasResults && !hasEligibleGroups` → `.reviewList`;
    - `hasResults` → `.review` (Duck Mode);
    - else `.freshScan` (WS-26 made it incremental).

    `PhotoDuckShellView` passes `similarGroups.contains(where: \.isAutoCleanEligible)` and `viewModel.photoAccessNeedsSettings`. Titles: `.openSettings` "Open Settings", `.reviewList` "Review Groups". `.reviewList` sets `showReviewResults = true`.
  - Disable the dock "Review" button and the "Review Results" menu item when `similarGroups.isEmpty`.
  - When `viewModel.photoAccessNeedsSettings`, the Similar tab's `emptyState` shows the access copy and a button calling `viewModel.openPhotoAccessSettings()` instead of the scan button.
- **Edge cases:** `.limited` authorization is not "access needed" (limited access keeps working everywhere; invariant 20).

**WS-31.6 — Completion notifications: content, targets, bootstrap order and cold-launch routing (STATE-13)**
- **Change:**
  - New `Views/Home/CompletionNotificationContent.swift`:
    ```swift
    enum CleanupReviewTarget: String, Sendable {
        case reviewGroups, reviewScreenshots, reviewBlurry, reviewLargeVideos, retryUnanalyzed, home
        init?(storedValue: String) { self.init(rawValue: storedValue == "reviewResults" ? "reviewGroups" : storedValue) }
    }
    struct CompletionNotificationContent: Equatable {
        let title: String; let body: String; let target: CleanupReviewTarget
        static func make(_ outcome: ScanOutcomeSummary, unanalyzed: Int) -> CompletionNotificationContent
    }
    enum NotificationTargetRouting {
        enum ShellTab { case home, similar, files }
        static func destination(for target: CleanupReviewTarget) -> (tab: ShellTab, homeRoute: HomeRoute?)
    }
    ```
    - `make`:
      - nothingFound → ("Your library looks clean", "PhotoDuck checked your library and found nothing to clean up.", `.home`);
      - analysisFailed or incomplete with no actionable opportunity → ("Scan finished with issues", "\(CountText.photos(n)) couldn't be analyzed. Tap to retry.", `.retryUnanalyzed`);
      - otherwise ("Scan complete", "Tap to review \(top opportunity line).", the target of the top opportunity).

      "Looks clean" appears only for nothingFound.
    - `destination`: `.reviewGroups` → Similar tab; `.reviewLargeVideos` → Files tab; `.home` → Home tab; `.reviewScreenshots`/`.reviewBlurry`/`.retryUnanalyzed` → Home with the matching `HomeRoute`.
  - Delete the old `CleanupReviewTarget` at `HomeViewModel.swift:2593-2595`. `CleanupNotificationScheduler.schedule` takes the new target. `CleanupNotificationRouter.Target` becomes `typealias Target = CleanupReviewTarget`; `didReceive` decodes with `init(storedValue:)`. Add `@MainActor func consumePendingTarget() -> CleanupReviewTarget?`, which returns the value and sets it to nil. Keep `willPresent` returning `[]` (invariant 26).
  - WS-15's `CompletionNotificationService.notifyRunCompleted` takes `ScanOutcomeSummary` (plus the unanalyzed count) and uses `CompletionNotificationContent.make`. Keep the existing `notificationKey` de-duplication.
  - In the completion block, call `notifyRunCompleted` only when WS-26's `activeScanOrigin == .userInitiated` (read at the same point WS-26 issues `completedUserScanToken`, so a user tap that upgraded an automatic run still gets its alert). Automatic runs never post a completion notification; they surface only WS-26's `AutomaticScanNotice` toast.
  - `PhotoDuckShellView`:
    - add `private func handle(_ target: CleanupReviewTarget?)` that switches tab from `NotificationTargetRouting.destination` and, for Home routes, sets `dashboardModel.pendingHomeRoute = route`;
    - call it from `.onAppear { handle(notificationRouter.consumePendingTarget()) }` **and** `.onChange(of: notificationRouter.pendingTarget) { _ in handle(notificationRouter.consumePendingTarget()) }`.
  - `HomeViewModel`: `@Published var pendingHomeRoute: HomeRoute?`. `HomeView` observes it in `.onAppear` and `.onChange`, calls `open(route)` and clears it.
  - Bootstrap order: in the bootstrap Task (wherever WS-15/WS-17/WS-26–WS-28 left it), `await` the notification service's `refreshAuthorization()` **before** `scanNewPhotosIfNeeded()`. Also call `refreshAuthorization()` from `updateScenePhase(.active)`. The existing `refreshPersistenceHealth()` call may move up with it, but treat it as interim: WS-47 (chapter 10) deletes `refreshPersistenceHealth()` and every call to it, including this one. Add no tests or new call sites that depend on it.
- **Edge cases:**
  - Whether the footer shows "Notify me" is WS-29's rule: `ScanFooterPresentation.showsNotifyMe(for: backgroundContinuationState)`, true only when a continuation was scheduled. Keep that gate unchanged. This task only makes `notificationEligible` correct early.
  - A notification delivered by the previous build carries "reviewResults" and maps to `.reviewGroups`.

### Tests
All in the simulator.
- `iOSCleanupTests/ScanOutcomeSummaryTests.swift`:
  - `testRT2AllUnanalyzedWithOneScreenshotIsAnalysisFailed`: analyzed 0, unanalyzed 14, screenshots 1 → `.analysisFailed(14)`. `title` and `heroStatus` never contain "clean" or "complete". `detail` contains "14 photos". `primaryAction == .route(.screenshots)`. The opportunity line says "1 screenshot".
  - `testOneGroupIsSingular`: headline and lines contain "1 group" and never "1 groups".
  - `testZeroBytesRenderZeroMB`: `ByteText.stat(0) == "0 MB"`.
  - `testNothingFoundOnlyWhenNoUnanalyzed`: all zero → `.nothingFound`, `.done`; the same with unanalyzed 1 → `.incomplete`.
  - `testLargeVideosOutrankDuplicatesByDeviceBytes`.
  - `testReviewOnlySimilarSortsLastAndIsNeverPrimaryWhenActionableExists`.
  - `testICloudOnlyBytesNeverReportedAsOnThisIPhone`.
  - `testCleanupCompleteRequiresSessionDeletions`.
  - `testPrimaryActionIsNeverForcedRescan`: every `PrimaryAction` over a table of inputs is `.route` or `.done`.
  - `testCountTextLocalizedGrouping`: 1,800 → "1,800 screenshots" under the `en_US` default.
  - `testCompletionAndDashboardCopyUseSharedFormatters`: scan `Views/Home/CompletionOverlay.swift` and `Views/Home/HomeDashboardPresentation.swift` sources (DesignLintTests-style `#filePath` walk) for `ByteCountFormatter`; expect none.
- `iOSCleanupTests/HomeDashboardPresentationTests.swift`:
  - `testNonCompletedStatesMatchLegacyCopy`: a table of every non-completed `HeroState` with fixed inputs, asserting the moved strings; written **before** the move. It includes the chapter 06 interim rows listed in WS-31.3 (pre-pass, finishing, video-pass progress, "checks new photos", auto-resume blocked), with `ctaIsEnabled == false` for the pre-pass row.
  - `testCompletedHeroUsesOutcome`.
  - `testCompletedNoFindingsCTARefreshesIncrementally`: `ctaAction == .refreshScan`.
  - `testCompletedWithScreenshotsRoutesToScreenshots`.
  - `testAnalysisFailedNeverSaysCleanupComplete`.
- `iOSCleanupTests/ResultsEmptyContextTests.swift`:
  - `testUnanalyzedIsNeverCelebration`.
  - `testDeniedIsAccessNeeded`.
  - `testLimitedIsNotAccessNeeded`.
  - `testScanningIsNeutral`.
  - `testCompletedCleanIsCelebration`.
- `iOSCleanupTests/CompletionNotificationContentTests.swift`:
  - `testCleanBranch`.
  - `testUnanalyzedOnlyBranchTargetsRetry`.
  - `testScreenshotsOnlyBranchTargetsScreenshots`.
  - `testGroupsBranchTargetsGroups`.
  - `testLegacyReviewResultsValueMapsToGroups`.
  - `testDestinationMapping`: all six targets.
  - `@MainActor testPendingTargetSetBeforeAppearIsConsumedOnce`: set `router.pendingTarget = .reviewScreenshots` on a new router; the first `consumePendingTarget()` returns it and the second returns nil.
- `iOSCleanupTests/HomeViewModelTests.swift` (WS-07/WS-08 harness, WS-15's fake notification center with an authorized status): `testAutomaticRunNeverSchedulesCompletionNotification`. An automatic `scanNewPhotosIfNeeded()` run completes with no `schedule` call; a run started with `startPhotoScan(from: .homePrimaryCTA)` schedules exactly one.
- Extend `iOSCleanupTests/PhotoScanEngineTests.swift` `testSimilarPhotosPrimaryActionProtectsActiveScanProgress` with: accessDenied → `.openSettings`; results with no eligible groups → `.reviewList`; eligible → `.review`.

### Acceptance criteria
- [ ] Completion sheet, hero, CTA, Similar and results empty states and completion notifications all derive from `ScanOutcomeSummary` or `ResultsEmptyContext` (code review plus tests for findings, nothingFound, incomplete and analysisFailed).
- [ ] The RT-2 fixture (`testRT2AllUnanalyzedWithOneScreenshotIsAnalysisFailed`) passes. "Cleanup complete" or "looks clean" never appears when unanalyzed > 0.
- [ ] `grep -rn "restartPhotoScan" iOSCleanup` finds nothing (WS-26 deleted it), and `grep -rn "gearRescanConfirmed" iOSCleanup/Views` shows only the confirmed gear-menu call site. No presentation action forces a full rescan.
- [ ] Chapter 06's interim hero, CTA and footer copy survives the move unchanged (`testNonCompletedStatesMatchLegacyCopy`), and "Notify me" is still gated by `ScanFooterPresentation.showsNotifyMe(for:)`.
- [ ] A notification tapped from a cold launch opens the screen its text names (device QA). `testPendingTargetSetBeforeAppearIsConsumedOnce` passes.
- [ ] The automatic launch scan never posts a completion notification (`testAutomaticRunNeverSchedulesCompletionNotification`) and never offers "Notify me" (WS-29 gate). Authorization is refreshed before `scanNewPhotosIfNeeded()`, so `notificationEligible` is already correct for the first user scan (code review of the bootstrap order).
- [ ] `HomeViewModel` changes are forwarding one-liners plus the session counter and `pendingHomeRoute`. New types live in new files added to `project.pbxproj`. Zero new warnings.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. Allow completion alerts. Start a Deep Clean. Switch to another app until the alert arrives. Tap it; the screen matches the text (screenshots, Large Videos or Similar).
2. Force-quit PhotoDuck. Tap a delivered PhotoDuck alert from Notification Center; cold launch lands on the described screen.
3. In airplane mode on an Optimize-storage library, retry unanalyzed photos. The completion sheet says "Scan incomplete" or "Couldn't analyze your photos", with a retry action and never "clean".
4. With notifications already allowed, relaunch with new photos. The scan footer never offers "Notify me" for this launch scan, and no completion alert arrives for it (automatic scans show only the in-app toast).

### Pitfalls and out of scope
- Do not move `heroState` or change when the completion sheet presents (WS-26/WS-27 token). Do not reorder Home tiles (WS-45).
- The global plural and format lint and the sweep of remaining strings belong to WS-56 (chapter 12). Here, convert only strings you touch.
- `HomeRoute` pushes coexist with WS-55's later navigation-stability work. Keep `homePath` simple (append/removeAll) so WS-55 can adopt it.
- Storage card and stat-tile relabeling are WS-32. Byte-led tile order is WS-45.
- Keep `willPresent` returning `[]` and the delegate installed in `App.init` (invariant 26).
- **Reconciliation:**
  - L26: `HomeCTAAction` and `HomeCTAAction.resolve` live in their own file created here; WS-45 extends them. L10: the nested `CleanupOpportunity.Kind` is the only kind name. L25: forward note in WS-31.2.
  - Chapter 06's interim copy (the WS-27 pre-pass and video-pass lines, the WS-26 "checks new photos" subtitle, WS-28's auto-resume-blocked message and WS-29's footer) is carried through the verbatim move. Only automatic-vs-user origin (WS-26's `activeScanOrigin`) decides whether a completion notification is posted, and "Notify me" stays behind WS-29's continuation gate.
  - Scan actions use WS-26's public `startPhotoScan(from:)` (`.homePrimaryCTA`, `.completionSheetScanAgain`), because `refreshPhotoScan()`/`rescanEntireLibrary()` are private and `restartPhotoScan()` is deleted.
  - `refreshPersistenceHealth()` is interim (WS-47 deletes it).
  - Lead item (chapters 03–04 final): the session deletion counter extends WS-21's `applyConfirmedDeletion(assetIDs: Set<String>)` (`itemCount == assetIDs.count`) instead of a "DeletionReceipt hook".
  - Chapter 06 is a prerequisite in execution order (WS-27–WS-29 land before this workstream), although the dependency row lists only WS-26.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| UI-06 | confirmed | Every cited branch exists at the lines listed above (HomeView 1036-1070, 364/391/446; HomeViewModel 638/655/712). Types live in new files, not HomeViewModel.swift. The byte formatter is `ByteText.stat` ("0 MB", matching today's StatPill) rather than a formatter with `allowsNonnumericFormatting = false`. |
| VALUE-04 | confirmed | The CTA and sheet ignore screenshots and large videos. `CleanupOpportunity` is adopted inside `ScanOutcomeSummary`. A separate `HeroState.analysisUnavailable` case is **not** added: the outcome's `kind` drives copy inside `.completedResultsAvailable`, which avoids touching every `HeroState` switch. |
| BUILD-11 | partially | The copy-testability part is real and fixed by `HomeDashboardPresentation`. Its "inject engine factory" part is already delivered by WS-07's `HomeViewModelDependencies`, so it is out of scope here. |
| UI-07 | confirmed | PhotoResultsView.swift:70-75, EmptyStateView default `.celebration`, and the shell dock/menu (459-461, 247) are as described. `.cleanedEverything` is decided inside `PhotoResultsView` from `hiddenGroupIDs`. |
| STATE-13 | confirmed | Bootstrap order (HomeViewModel.swift:326-330), `.onChange`-only consumption (PhotoDuckShellView.swift:88-95) and the single target (2594) are verified. Adds `.reviewLargeVideos` and `.home` to the proposed targets, so large-video-led and clean outcomes route sensibly. |

---

## WS-32 — Honest storage and "freed" accounting

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-11, WS-30, WS-31 | no | `ws/32-honest-storage-freed` |

**Primary files:** `iOSCleanup/Utilities/StorageMeasurementService.swift` (*new*), `iOSCleanup/Engines/DeletionManager.swift`, `iOSCleanup/Engines/CleanupStats.swift` (*new, moved from DeletionManager.swift*), `iOSCleanup/Views/Home/StorageSummaryCard.swift` (*new*), `iOSCleanup/Views/Home/FinishFreeingSpaceCard.swift` (*new*), `iOSCleanup/Views/HomeViewModel.swift` (delegation only), `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/Views/Files/LargeVideoRowViews.swift`, `iOSCleanup/Utilities/CountText.swift`, `iOSCleanup/Views/Photos/SwipeModeView.swift`, `iOSCleanup/Views/Photos/SwipeModeViewModel.swift`, `iOSCleanupTests/CleanupStatsStoreTests.swift` (*new*), `iOSCleanupTests/StorageMeasurementTests.swift` (*new*), `iOSCleanupTests/DesignLintTests.swift`
**Findings covered:** DEL-07 (P1, confirmed; merged: VALUE-03 confirmed, UI-10 confirmed), STORE-12 (P2, confirmed; merged: FSA-07 confirmed), FILES-23 (P3, confirmed)
**Decisions applied:** D-UNDO: recovery is Recently Deleted (30 days), so the honest verb is "sent to Recently Deleted", and WS-11's receipt is the event source.

### Goal
The Home storage bar shows the same free space as Settings (important-usage capacity) and is re-measured on `.active` and after every commit. Its PhotoDuck segments count only measured on-device bytes, with large videos as their own row and iCloud-only bytes in a footnote. "Freed with PhotoDuck" becomes "Sent to Recently Deleted (≈)". A 30-day ledger drives a dismissible "Finish freeing space" card with manual steps. Duck Mode's completion screen shows the receipt. No screen claims a percentage of the device. Compression savings have an API ready for WS-44. File-size parts use one decimal formatter.

### Current behavior (verified)
- `iOSCleanup/Engines/DeletionManager.swift:17-20` `struct CleanupStats: Codable { var lifetimeBytesFreed; var lifetimeItemsFreed }` uses a synthesized decoder, so adding a non-optional key would break v1 JSON. `:22-62` `CleanupStatsStore` (UserDefaults key `photoduck.cleanup-stats.v1`). `:135-142` and `:171-178` record `estimatedBytes(for:)` immediately after `performDelete`, when items have only moved to Recently Deleted. WS-11 turns these into `DeletionReceipt`s.
- `iOSCleanup/Views/HomeView.swift:597-605` stat tiles "Freed with PhotoDuck" (`lifetimeBytesFreed.formattedBytesStat`) and "Items cleaned". `:594-597` "Photos + videos" = `reclaimableFormatted`.
- `HomeView.swift:737-787` `foundFraction = reclaimableBytes / storageTotalBytesValue`, clamped to used, is drawn inside the "iPhone storage" used bar with the legend "Found by PhotoDuck: X". Large videos and iCloud-only bytes are included.
- `iOSCleanup/Views/HomeViewModel.swift:556-579`: `storageInfo` reads `attributesOfFileSystem(…)[.systemFreeSize]` (excludes purgeable, unlike Settings). It is cached in a private non-published `_storageInfo` and invalidated only at 1520 (`removeLargeFileFromResults`) and 1901 (reconcile). WS-21 adds invalidation on `.active`.
- `iOSCleanup/PrivacyInfo.xcprivacy:23-28` already declares DiskSpace reasons `E174.1` and `85F4.1`.
- `iOSCleanup/Views/PhotoDuckShellView.swift:151-155` `reclaimablePercent = reclaimable / storageTotalBytesValue`, and `:168` shows "Can free up \(n)% of storage".
- `iOSCleanup/Views/Photos/SwipeModeViewModel.swift:47-48` `deletedCount`/`deletedBytes` are `private(set)` and not published. `SwipeModeView.swift:277-363` completion screen shows "Potential space" before commit and nothing after.
- `iOSCleanup/Views/Files/VideoCompressionView.swift:336-343`: `.savedAndDeleted` records no savings.
- `iOSCleanup/Views/Files/FileResultsView.swift:1525-1533` `splitSize` divides by 1,073,741,824 / 1,048,576 (binary). Grid cards and the compression header use decimal `LargeFile.formattedSize` (`Models/LargeFile.swift:32-34`). WS-10 moves `FileRow` to `LargeVideoRowViews.swift`.
- `grep -rn "photos-redirect" iOSCleanup` finds nothing, and nothing tells users to empty Recently Deleted except fine print (`PhotoGroupDetailView.swift:111`, `SwipeModeView.swift:340`, `PhotoResultsView.swift:522`).

### Implementation plan

**WS-32.1 — `StorageMeasurementService`**
- **Why:** `systemFreeSize` understates "Available" relative to Settings and is never re-measured after cleanup (STORE-12, VALUE-03).
- **Change:** new file `iOSCleanup/Utilities/StorageMeasurementService.swift`:
  ```swift
  struct StorageVolumeValues: Equatable, Sendable {
      var totalCapacity: Int64?; var availableForImportantUsage: Int64?; var systemFreeSize: Int64?
      static func live() -> StorageVolumeValues   // URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
                                                  //   forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
                                                  // plus attributesOfFileSystem fallback
  }
  struct StorageSnapshot: Equatable, Sendable {
      let totalBytes: Int64; let availableBytes: Int64; let measuredAt: Date
      var usedBytes: Int64 { max(totalBytes - availableBytes, 0) }
      var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
      static func make(_ values: StorageVolumeValues, now: Date) -> StorageSnapshot?  // prefers important-usage,
                                                   // falls back to systemFreeSize; nil without a positive total
  }
  @MainActor final class StorageMeasurementService: ObservableObject {
      @Published private(set) var snapshot: StorageSnapshot?
      init(read: @escaping @Sendable () -> StorageVolumeValues = StorageVolumeValues.live, now: …)
      func refresh()   // reads in Task.detached(priority: .utility), assigns on main; coalesces overlapping calls
  }
  ```
  - `HomeViewModel` owns one instance (a `HomeViewModelDependencies` entry, with the live default) and forwards `objectWillChange`. Delete `StorageInfo`/`_storageInfo` and turn `storageUsedFraction`, `storageUsedFormatted`, `storageFreeFormatted` and `storageTotalBytesValue` into forwards to `snapshot` (formatted with `ByteText.stat`; "—" when nil). Remove the `_storageInfo = nil` lines (1520, 1901, and WS-21's `.active` and `applyConfirmedDeletion` ones).
  - Call `refresh()` at bootstrap, on `updateScenePhase(.active)`, after each confirmed commit, and from `removeLargeFileFromResults`. For the commit case, WS-32 extends WS-21's `applyConfirmedDeletion(assetIDs: Set<String>)`, which receives `DeletionManager.confirmedDeletions` once per confirmed commit. Add `func refreshStorage()` for WS-44 to call after compression.
- **Edge cases:** The volume query can take tens of milliseconds, so never run it on main. Do not add a "measured free-space delta" claim (out of scope; the milestone checks it by device QA).

**WS-32.2 — `CleanupStats` ledger**
- **Why:** "Freed" is claimed at the moment bytes reach Recently Deleted, and nothing tracks what still waits there (DEL-07).
- **Change:** move `CleanupStats`/`CleanupStatsStore` from `DeletionManager.swift:17-62` into new `iOSCleanup/Engines/CleanupStats.swift`, then:
  ```swift
  struct RecentlyDeletedEntry: Codable, Equatable, Sendable {
      enum Source: String, Codable, Sendable { case deletion, compressionOriginal, external }
      var day: Date          // Calendar.current.startOfDay(for:) — one entry per day and source
      var bytes: Int64; var itemCount: Int; var source: Source
  }
  struct CleanupStats: Codable, Equatable, Sendable {
      static let recentlyDeletedRetention: TimeInterval = 30 * 86_400
      var lifetimeBytesFreed: Int64 = 0        // key kept for v1 JSON; meaning: bytes sent to Recently Deleted (≈)
      var lifetimeItemsFreed: Int = 0
      var lifetimeCompressionSavedBytes: Int64 = 0
      var recentlyDeleted: [RecentlyDeletedEntry] = []
      var finishFreeingDismissedAt: Date?
      init() {}
      init(from decoder: Decoder) throws  // decodeIfPresent for EVERY key, defaulting as above
      func pendingRecentlyDeletedBytes(now: Date) -> Int64   // entries with day > now - retention
      mutating func prune(now: Date)
  }
  ```
  - `CleanupStatsStore(defaults:now:)` exposes:
    - `recordConfirmedDeletion(bytes:itemCount:)`: adds to the lifetime totals and today's `.deletion` entry, prunes, saves;
    - `recordCompressionSavings(originalBytes:outputBytes:)`: `lifetimeCompressionSavedBytes += max(original - output, 0)`, and today's `.compressionOriginal` entry `+= originalBytes`, because the original now sits in Recently Deleted;
    - `recordExternalReclaim(bytes:itemCount:)`: an `.external` entry for PhotoKit deletions not issued by `DeletionManager` (today only the compression swap, via `recordCompressionSavings`);
    - `dismissFinishFreeing()`: sets `finishFreeingDismissedAt = now`.

    The custom decoder leaves room for WS-64's monthly buckets (additive keys).
  - `DeletionManager` publishes `@Published private(set) var cleanupStats: CleanupStats` (keep `lifetimeBytesFreed`/`lifetimeItemsFreed` as computed forwards) and exposes forwarding `recordCompressionSavings(originalBytes:outputBytes:)`, `recordExternalReclaim(bytes:itemCount:)` and `dismissFinishFreeingCard()`. Record only where WS-11 records today, after PhotoKit confirms (invariant 9).
  - **L6:** `recordCompressionSavings(originalBytes: Int64, outputBytes: Int64)` is the only compression-accounting API. Do not add a `recordCompressionSavings(bytes:)` variant. WS-44 calls it through the `DeletionManager` environment object only on `.replaced`: the original enters the Recently Deleted ledger as `.compressionOriginal`, and only the net saving goes to `lifetimeCompressionSavedBytes`.
- **Edge cases:**
  - Prune on load, so a year-old ledger does not linger.
  - Same-day entries coalesce, so the array stays at 31 entries or fewer per source.
  - Use saturating adds, as the existing `addingWithoutOverflow` does.

**WS-32.3 — Storage card: device-only segments, videos as their own row**
- **Why:** The bar shades iCloud-only originals and every large video as "found" iPhone space (STORE-12, FSA-07, VALUE-02 item 4-5).
- **Change:** move `storageCard`, `foundFraction` and `legendItem` out of `HomeView.swift` into new `Views/Home/StorageSummaryCard.swift`. Drive them with a pure presentation:
  ```swift
  struct StorageCardPresentation: Equatable {
      struct Segment: Equatable { enum Kind { case photos, largeVideos }; let kind: Kind; let fraction: Double; let label: String }
      let title: String                 // "iPhone storage"
      let availableLabel: String        // "X available"
      let usedFraction: Double; let usedLabel: String
      let segments: [Segment]           // photo delete candidates on device, large videos on device (review)
      let notes: [String]               // iCloud-only line, still-measuring line, Recently Deleted line
      static func make(storage: StorageSnapshot?, photos: ReclaimSizing, largeVideos: ReclaimSizing, hasCompletedScan: Bool) -> Self
  }
  ```
  - Segments use `deviceBytes / totalBytes` only. Their sum is clamped to `usedFraction`.
  - Labels: "Duplicates on this iPhone ≈X" and "Large videos on this iPhone ≈Y (review)".
  - Notes:
    - `iCloudOnly > 0` → "≈Z more is stored only in iCloud; deleting it frees iCloud storage, not iPhone storage.";
    - `iCloudOnly > device` (photos plus videos) → prepend "Optimize iPhone Storage is on, so most of what PhotoDuck found lives in iCloud.";
    - `unknownLocality > 0` → "≈U is still being measured.";
    - always, when any segment exists → "Space is freed after Recently Deleted is emptied."

  `DECISION (owner may override): the storage bar never counts unmeasured bytes as iPhone space; they appear only as a "still being measured" note.` Inputs come from `viewModel.dashboardSummary.photoReclaimSizing` and `.largeVideoSizing` (WS-30). Keep the existing bar-and-legend look and tokens; this is Home, not a design-pending screen.
- **Edge cases:** A nil snapshot hides the bar and shows only notes. No label contains "%".

**WS-32.4 — Stat tiles and the "Finish freeing space" card**
- **Change:**
  - `HomeView.statsRow`: the "Photos + videos" tile becomes value `ByteText.approximate(photos + largeVideos device-only sizing)` with label "On this iPhone". "Freed with PhotoDuck" becomes value `"≈" + ByteText.stat(lifetimeBytesFreed)` with label "Sent to Recently Deleted". "Items cleaned" stays.
  - New `Views/Home/FinishFreeingSpaceCard.swift` with a pure model:
    ```swift
    struct FinishFreeingSpaceModel: Equatable {
        let headline: String   // "≈X is waiting in Recently Deleted"
        let steps: String      // "iOS removes it after 30 days. To free it now: open Photos › Albums › Recently Deleted › Select › Delete All."
        let iCloudNote: String?// "With iCloud Photos, part of this frees iCloud storage rather than iPhone storage."
        static func make(stats: CleanupStats, now: Date, libraryHasICloudOnlyItems: Bool) -> FinishFreeingSpaceModel?
    }
    ```
    - Show only when `pendingRecentlyDeletedBytes(now:) > 0` **and** (no dismissal, or some entry's `day` ≥ the dismissal day, meaning a newer deletion).
    - `libraryHasICloudOnlyItems` = any WS-30 sizing with `iCloudOnlyBytes > 0`.
    - The card is a `DuckCard` with the text and a "Dismiss" text button → `deletionManager.dismissFinishFreeingCard()`. Insert it on Home right after `ctaButton`.
    - **Instructions only:** no `photos-redirect://` or any other URL scheme.

    `DECISION (owner may override): a dismissed card stays hidden until a newer deletion is recorded.`
- **Edge cases:** Compression originals also appear in the pending total. That is correct: they sit in Recently Deleted.

**WS-32.5 — Duck Mode receipt**
- **Change:**
  - `SwipeModeViewModel`: make the committed-session totals `@Published private(set)`. After WS-12 these come from the `DeletionReceipt`s consumed in `commitDeletes`; sum `itemCount` and `estimatedBytes`.
  - `SwipeModeView` completion screen: when the committed count > 0, add `Text("Moved \(CountText.photos(n)) (≈\(ByteText.stat(bytes))) to Recently Deleted.")` in `.duckBody` and `Text("To free the space now: Photos › Albums › Recently Deleted › Select › Delete All.")` in `.duckCaption`, `Color.textSecondary`. Replace the existing "Potential space is reclaimed…" caption only after a commit. Functional text only; no layout redesign (Duck Mode awaits the handoff).

**WS-32.6 — Library-relative wording on the Similar tab**
- **Change:** in `PhotoDuckShellView`, delete `reclaimablePercent` (151-155). `dashboardSubtitle` becomes `"\(ByteText.approximate(photoReclaimSizing)) in \(CountText.groups(n))" + (device > 0 ? " · ≈\(ByteText.stat(device)) on this iPhone" : "")`. `heroMetricText` uses the same sizing. `storageTotalBytesValue` loses its last Similar-tab use.

**WS-32.7 — One decimal file-size parts helper (FILES-23)**
- **Change:** add to `ByteText` in `CountText.swift`:
  ```swift
  static func parts(_ bytes: Int64) -> (number: String, unit: String) {
      let number = ByteCountFormatter(); number.countStyle = .file; number.includesUnit = false
      let unit = ByteCountFormatter(); unit.countStyle = .file; unit.includesCount = false
      return (number.string(fromByteCount: bytes), unit.string(fromByteCount: bytes))
  }
  ```
  In `LargeVideoRowViews.swift`, `FileRow.fileSizeView` uses `ByteText.parts(file.byteSize)`, with the prefix `≈` when `byteSizeIsEstimated`. Delete `splitSize`.

**WS-32.8 — Copy lint**
- **Change:** in `iOSCleanupTests/DesignLintTests.swift`, add `testNoFreedClaimsPercentOfStorageOrPrivatePhotosURL`, using the existing `scanViews` helper. It fails on "Freed with PhotoDuck", "% of storage" or "photos-redirect".

### Tests
All in the simulator.
- `iOSCleanupTests/CleanupStatsStoreTests.swift` (WS-64 extends this file):
  - `testV1JSONDecodesIntoNewStats`: `{"lifetimeBytesFreed":123,"lifetimeItemsFreed":4}` in a suite-named `UserDefaults`.
  - `testDeletionAddsLifetimeAndPendingLedger`.
  - `testLedgerPrunesAfter30Days`: injected `now`.
  - `testSameDayEntriesCoalesce`.
  - `testCompressionSavingsAddSavedBytesAndPendingOriginal`: original 1,000, output 400 → saved 600, pending 1,000, and `lifetimeBytesFreed` unchanged.
  - `testDismissHidesCardUntilNewerDeletion`: uses `FinishFreeingSpaceModel.make`.
  - `testFinishFreeingCopyHasStepsAndNoURLScheme`.
- `iOSCleanupTests/StorageMeasurementTests.swift`:
  - `testSnapshotPrefersImportantUsageCapacity`.
  - `testSnapshotFallsBackToSystemFreeSize`.
  - `testSnapshotNilWithoutTotal`.
  - `@MainActor testRefreshPublishesInjectedValues`: poll with a deadline, no sleeps.
  - `testCardNeverCountsICloudOnlyBytesAsDevice`.
  - `testLargeVideosAreTheirOwnSegment`.
  - `testUnmeasuredBytesOnlyInNotes`.
  - `testOptimizeExplainerWhenICloudDominates`.
  - `testNoLabelContainsPercent`.
  - `testFileSizePartsAreDecimal`: `ByteText.parts(2_050_000_000)` → unit "GB" and number starting with "2" (binary would give "1.9").
- `DesignLintTests.testNoFreedClaimsPercentOfStorageOrPrivatePhotosURL`.
- **Device only:** Settings match and the Recently Deleted end-to-end (Device QA).

### Acceptance criteria
- [ ] Free space shown on Home equals Settings › General › iPhone Storage "Available" within rounding (device QA). The value refreshes on `.active` and after a commit.
- [ ] The storage bar and the "On this iPhone" tile contain only measured on-device bytes. Large videos have their own row. iCloud-only and unmeasured bytes appear only in notes (tests).
- [ ] No UI string says "Freed with PhotoDuck", "% of storage" or uses `photos-redirect` (lint test).
- [ ] After any deletion, the Finish-freeing card appears with manual steps. Dismissal holds until the next deletion (tests plus device QA).
- [ ] Duck Mode shows "Moved N photos (≈X) to Recently Deleted" after a commit.
- [ ] Old `photoduck.cleanup-stats.v1` data decodes without loss (test). `recordCompressionSavings` exists for WS-44.
- [ ] `ios-cleanup/CLAUDE.md` no longer says "freed" for pending bytes. The `DeletionManager` row mentions the Recently Deleted ledger. Zero new warnings.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. Compare Home "available" with Settings › General › iPhone Storage. Record both; they should match within rounding.
2. Keep Best on N groups. Note PhotoDuck's "On this iPhone" figure for those groups and the card's pending total. In Photos, empty Recently Deleted. Back in PhotoDuck (`.active`), record the change in free space. **Milestone check:** the delta is within ±20% of PhotoDuck's on-device figure.
3. Dismiss the card, delete one more photo, and confirm the card returns.
4. Commit a Duck Mode queue and confirm the receipt line.

### Pitfalls and out of scope
- Never count bytes as freed before PhotoKit confirms (invariant 9). Never add the compression original to `lifetimeBytesFreed`.
- WS-44 calls `recordCompressionSavings` only on `.replaced` (after WS-43). This workstream does not wire compression. WS-64 adds monthly buckets and the recap card on top of this decoder.
- Byte-led tile ordering is WS-45 (chapter 09). The global count and format sweep is WS-56 (chapter 12).
- Do not use `photos-redirect://` or any undocumented scheme (App Review risk). Instructions only.
- **Reconciliation:**
  - L6: `recordCompressionSavings(originalBytes:outputBytes:)` is canonical, with no `bytes:` variant. Chapter 09's WS-44 text that calls `recordCompressionSavings(bytes:)` must use this signature.
  - L28: `CleanupStats`/`CleanupStatsStore` live in `iOSCleanup/Engines/CleanupStats.swift` from this workstream on; WS-60/WS-64 edit that file, not `DeletionManager.swift`.
  - Lead item (chapters 03–04 final): there is no separate "DeletionReceipt hook". WS-21 publishes confirmed deletions as `Set<String>` into `applyConfirmedDeletion(assetIDs:)` (with `itemCount == assetIDs.count`), and WS-32 extends that function.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| DEL-07 | confirmed | Stats are recorded at `performDelete` success (DeletionManager.swift:135-142, 171-178) and labeled "Freed" (HomeView.swift:600). There is no guidance. One test expectation is corrected: compression originals **do** count toward the pending Recently Deleted total, because the original sits there. Only the net saving (original − output) goes to the separate compression-savings total. |
| VALUE-03 | confirmed | `systemFreeSize` plus the private, rarely invalidated cache is confirmed (HomeViewModel.swift:556-579). Its `photos-redirect://` button is rejected (undocumented scheme). The "measured delta" claim is dropped in favor of device QA. |
| UI-10 | confirmed | Same evidence. Uses a per-day ledger instead of a single `lastDeletionAt`. |
| STORE-12 | confirmed | The percentage (PhotoDuckShellView.swift:151-168) and `systemFreeSize` are confirmed. Fixed with important-usage capacity and library-relative wording. |
| FSA-07 | confirmed | `largeFileBytes` is included in `reclaimableBytes`/`foundFraction`. Videos now get their own segment and label "(review)"; they are not dropped entirely, because the user can act on them. The sheet parts were fixed in WS-31. |
| FILES-23 | confirmed | `splitSize` is binary (FileResultsView.swift:1525-1533) while other surfaces use decimal. Fixed with `ByteText.parts` (decimal `ByteCountFormatter`, `.file`). |

---

## WS-33 — Preference-learning safety and Release data collection

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-13 | no | `ws/33-preference-safety-ml-collection` |

**Primary files:** `iOSCleanup/Engines/PreferenceAdjustedRecommendationService.swift`, `iOSCleanup/Engines/PhotoPreferenceProfileStore.swift`, `iOSCleanup/Models/PhotoPreferenceProfile.swift`, `iOSCleanup/Models/PhotoReviewFeedback.swift`, `iOSCleanup/Engines/PhotoFeedbackStore.swift`, `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Engines/PhotoMLStore.swift`, `iOSCleanup/Utilities/PhotoDuckBuildFlags.swift` (*new*), `iOSCleanup/Engines/SimilarityCoreMLClassifier.swift`, `iOSCleanup/Engines/MLEnhancedKeeperRankingService.swift`, `iOSCleanup/Engines/PhotoScanEngine.swift` (one line), `iOSCleanup/Views/Photos/PhotoGroupDetailView.swift`, `MLTraining/README.md`, `CLAUDE.md`, `iOSCleanupTests/PreferenceAdjustedRecommendationTests.swift`, `iOSCleanupTests/PhotoFeedbackLearningTests.swift`, `iOSCleanupTests/PhotoMLStoreTests.swift`, `iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`
**Findings covered:** ML-04 (P1, confirmed; merged: SCAN-M01 confirmed, its sample-gating approach superseded), ML-10 (P2, confirmed; merged: FSA-17 confirmed, documented only)
**Decisions applied:**
- D-PREFS: preferences change queue priority only, and only once an aggregate has at least 8 decisions. No action or confidence changes. The `keeperMargin < 0.08` safety downgrade is kept (invariant 6).
- D-ML: no training collection in Release. The flag is `DEBUG || PHOTODUCK_ML_COLLECTION`. No model is bundled, and the JSON feedback journal stays on because priority uses it.

### Goal
No sequence of Keep Best, Auto-clean, Duck Mode or manual deletes can change which groups are Keep Best-eligible or how many bytes they reclaim; only queue order may change. Automation never counts as a human preference, and manual deletes in groups with no recommendation are not "rejections". Release builds write no `feedback_events` or `training_rows`, and the unused group-action model is compiled out. Docs say collection is DEBUG/internal and list the train/serve skew that must be fixed before any model ships.

### Current behavior (verified)
- `iOSCleanup/Engines/PreferenceAdjustedRecommendationService.swift` downgrades `keepBestTrashRest` → `reviewManually`, plus confidence, in three places:
  - edited `keepRate ≥ 0.60` (83-94);
  - favorites `keepRate ≥ 0.60` (96-107);
  - `acceptanceRate < 0.45` (128-132).

  It keeps the safety rule `keeperMargin < 0.08` (140-144) and the visuallySimilar/notSimilar guards (50-62). No rule has a minimum sample.
- `iOSCleanup/Models/PhotoPreferenceProfile.swift:28-32` `keeperAcceptanceRate` returns `0` with no samples, so a bucket with any committed event but no accept/reject downgrades. `:54` `schemaVersion = 1`.
- `iOSCleanup/Engines/PhotoPreferenceProfileStore.swift:66-93` `aggregateDelta`: `.keepBest, .swipeKeep` → `keptCount = 1`, even though Keep Best deletes N−1 photos. `:114-147` `ingest` merges into `edited`/`favorites` when **any** asset in the event matches. `:95-102` a different archive schema is ignored, and the next `rebuild` restores it.
- `iOSCleanup/Models/PhotoReviewFeedback.swift:244-249` and `Utilities/SharedHelpers.swift:491-497`: "edited" means `|modificationDate − creationDate| > 1 s`, a heuristic that also fires for favorites and imports (WS-37 fixes the signal).
- `iOSCleanup/Engines/PhotoFeedbackStore.swift:99-127` `recordAutoCleanDecisions` logs each auto-cleaned group as `.keepBest` from `.similarGroupReview`, with `recommendationAccepted: true` and note "Auto-clean all from results list". `:142-148` a `nil` `recommendationAccepted` is **derived** via `recommendationAccepted(kind:…)` (680-700), so passing `nil` from a view does not by itself mean "no recommendation".
- `iOSCleanup/Views/Photos/PhotoGroupDetailView.swift:257-266` `deleteSelected` passes `group.isAutoCleanEligible && deleteSet == Set(group.deleteCandidateIDs)`, which is `false` (a rejection) for every review-only group.
- `iOSCleanup/Engines/PhotoScanEngine.swift:1335-1360` applies `adjustment.adjustedSuggestedAction` and confidence, so a downgraded group gets `finalDeleteCandidateIDs = []` and reclaim 0.
- Tests:
  - `iOSCleanupTests/PreferenceAdjustedRecommendationTests.swift:7-27` pins the edited downgrade.
  - `:85-133` `testNoActionDependsOnArrayOrdering` uses a zero-sample `nearDuplicate` aggregate, so both inputs are silently downgraded; it asserts only equality.
  - `iOSCleanupTests/PhotoFeedbackLearningTests.swift:115, 189, 421` assert `overall.keptCount` for `.keepBest` events.
- `iOSCleanup/Engines/PhotoMLBridge.swift:260-297` `persistFeedbackEvent` dual-writes `feedback_events` plus `training_rows` in every build. `:307-380` export functions have no build gate. `Views/PhotoDuckShellView.swift:398` `exportMLTrainingData()` is not `#if DEBUG`; only its button is (254).
- `iOSCleanup/Engines/PhotoMLStore.swift:218-370` creates `feedback_events`, `feedback_assets` (316; never inserted) and `training_rows`. `:1120-1135` `groupOutcomeSQL` reads `feedback_assets`.
- `iOSCleanup/Engines/SimilarityCoreMLClassifier.swift:172-200` `MLGroupActionService`, `:280` `GroupActionFeatureProvider`, `:56` `GroupActionPredictionInput`. `MLEnhancedKeeperRankingService.swift:23, 115-150` `predictGroupAction` has no caller (grep).
- Skew (FSA-17):
  - inference `suggestedAction` uses `SimilarRecommendedAction` raw values (`SimilarityCoreMLClassifier.swift:379-381`), while training uses `SuggestedAction` (`PhotoFeedbackStore.swift:740-760`);
  - inference `fileSizeBytes: max(pixelCount, 1)` (~427), while training uses `estimatedFileSize`;
  - training `similarityToKeeper: nil` (`PhotoFeedbackStore.swift:586`).
- `photo_features` rows hold the Vision embedding (the warm-scan cache read via `loadValidAssetAnalyses`' join, `PhotoMLStore.swift:678-700`) **and** training metadata in the same row.

### Implementation plan

**WS-33.1 — Priority-only, sample-gated preferences**
- **Why:** One Auto-clean run or one review-only delete strips Keep Best from whole categories for good (ML-04, SCAN-M01).
- **Change (`PreferenceAdjustedRecommendationService.adjust`):**
  - Delete the three action and confidence mutations (88-92, 101-105, 128-132).
  - Delete the edited rule entirely, priority included. Remove `containsEdited` from `PreferenceAdjustedRecommendationInput` and its one line in `PhotoScanEngine.makeGroups` (`containsEdited: assets.contains(where: \.isEdited)`); keep the `PhotoScanEngine` edit to that line.
  - Keep the visuallySimilar and notSimilar guards and the `keeperMargin < 0.08` downgrade exactly as written. Note: WS-38 later exempts only verified-identical clusters; do not pre-empt it.
  - Add `static let minimumDecisionsForSignal = 8`. Every remaining priority rule (screenshots, bursts, favorites, bucket or group-type override/keep/delete, lowConfidence) applies only when that aggregate's `reviewedCount >= minimumDecisionsForSignal`.
  - Keep the final clamp `if adjustedAction != .keepBestTrashRest { queuePriorityDelta = min(queuePriorityDelta, 0.12) }`.
  - `PhotoDecisionAggregate.keeperAcceptanceRate` → `Double?` (nil when `accepted + rejected == 0`). Update `PhotoPreferenceProfile.keeperAcceptanceRate` and `debugSummaryLines` to print "n/a".
- **Edge cases:** The service must never *upgrade* an action. `adjustedSuggestedAction` now always equals the input, except for the visuallySimilar, notSimilar and margin rules.

**WS-33.2 — Profile semantics and schema v2**
- **Change:**
  - `PhotoPreferenceProfileStore.aggregateDelta`: `.keepBest` → `deletedCount = event.deletedAssetIDs.count`, `keptCount = 0`. Only `.swipeKeep` counts as a keep.
  - Add `extension PhotoReviewFeedbackEvent { static let legacyAutoCleanNote = "Auto-clean all from results list"; var isAutomation: Bool { source == .autoClean || note == Self.legacyAutoCleanNote } }` in `PhotoReviewFeedback.swift`. `ingest` returns early (after `totalRawEvents += 1`) for `isAutomation` events.
  - Bump `PhotoPreferenceProfile.schemaVersion` to 2, so the old archive is ignored and rebuilt from raw events. Add `func needsRebuild() async -> Bool` to `PhotoPreferenceProfileStore`. It is true after a load that found no valid archive and before any `rebuild`. `PhotoFeedbackStore.loadIfNeeded` rebuilds when `recoveredEvent || pruned || await profileStore.needsRebuild()`.
- **Edge cases:** `edited`/`favorites` aggregates keep being computed (Codable stability), but no rule reads `edited`.

**WS-33.3 — Recording: automation and review-only acceptance**
- **Change:**
  - Add `case autoClean` to `PhotoReviewFeedbackSource`. `recordAutoCleanDecisions(groups:)` (whatever calls it after WS-12) uses `source: .autoClean` and `recommendationAccepted: nil`.
  - In `makeSimilarGroupDecisionEvent`, compute acceptance as `group.isAutoCleanEligible ? (recommendationAccepted ?? Self.recommendationAccepted(…)) : nil`. A group that exposed no recommendation can never record an acceptance or rejection.
  - `PhotoGroupDetailView.deleteSelected` passes `recommendationAccepted: group.isAutoCleanEligible ? (deleteSet == Set(group.deleteCandidateIDs)) : nil`.
- **Edge cases:** Duck Mode swipes stay human signals. Keep Best from detail or list stays `.similarGroupReview`, with acceptance `true` (a human accepted it).

**WS-33.4 — `PhotoDuckBuildFlags` and the Release collection gate**
- **Change:** new file `iOSCleanup/Utilities/PhotoDuckBuildFlags.swift`:
  ```swift
  enum PhotoDuckBuildFlags {
      /// Training-data collection (feedback_events, training_rows, exports). Off in Release (D-ML).
      /// Enable for an internal build by adding PHOTODUCK_ML_COLLECTION to SWIFT_ACTIVE_COMPILATION_CONDITIONS.
      static let collectsMLTrainingData: Bool = {
          #if DEBUG || PHOTODUCK_ML_COLLECTION
          return true
          #else
          return false
          #endif
      }()
  }
  ```
  - `PhotoMLBridge.init(store:collectsTrainingData: Bool = PhotoDuckBuildFlags.collectsMLTrainingData)` stores `nonisolated let collectsTrainingData`.
  - **One gate (L23).** The compile-time flag `PhotoDuckBuildFlags.collectsMLTrainingData` feeds one runtime check named `collectsTrainingData`, and every training write, export and purge reads that check. Do not add a second flag or a differently named check. WS-46 (chapter 10) reuses the same gate, threading it into `PhotoMLStore(directoryURL:collectsTrainingData:)` to decide whether the training tables exist in the new cache file.
  - `persistFeedbackEvent(s)` return immediately when false. Export functions (`exportKeeperTrainingCSV`, `exportGroupOutcomeCSV`, `exportTrainingDataToDocuments`, `exportDatabaseToDocuments`) throw a new `MLExportError.collectionDisabled` when false. WS-47 later compiles them out.
  - `PhotoFeedbackPersisting` gains `nonisolated var collectsTrainingData: Bool { get }`. `PhotoFeedbackStore.append` skips the SQLite hand-off when false; the JSON journal is unchanged.
  - Add `PhotoMLStore.purgeTrainingCollection() throws`, deleting from `feedback_events`, `feedback_assets` and `training_rows` in one transaction. `PhotoMLBridge.performRetention` calls it first when `!collectsTrainingData`; it is cheap when empty.
  - Keep `CREATE TABLE` for these tables unchanged, so `stats()`, retention and `deleteAllData` never hit "no such table".
  - Scan-path `photo_features` writes stay as they are: those rows carry the embedding warm cache. WS-46 splits embeddings into their own table and drops the training metadata columns.
- **Edge cases:** Tests run in DEBUG, so they inject `collectsTrainingData: false` explicitly.

**WS-33.5 — Compile out the group-action model**
- **Change:** wrap in `#if DEBUG`: `GroupActionPredictionInput` (+ `extension GroupActionPredictionInput { init(group:) }`, ~455), `GroupActionFeatureProvider`, `MLGroupActionService`, the `GroupActionPredictionService` protocol and output type, the `mlGroupActionService` init parameter and property, and `predictGroupAction(for:)` in `MLEnhancedKeeperRankingService`. The keeper ranking path (`MLKeeperRankingService`, `LazyOptionalMLKeeperRankingService`) is untouched and stays dormant (no model bundled; invariant 5). Leave `groupOutcomeSQL`/CSV export to WS-47.
  - **Do not delete (L23)** `GroupActionFeatureSchema`, `groupOutcomeSQL`, `exportGroupOutcomeCSV` or the `feedback_assets` table. In Release they are unreachable, because the runtime gate throws `.collectionDisabled`. WS-47 moves the export code under `#if DEBUG`, and its `MLTrainingScriptSchemaTests` still asserts the group-action column list against `GroupActionFeatureSchema.modelInputNames`. Wrap `GroupActionFeatureSchema` in `#if DEBUG` only if every remaining user of it is already DEBUG-only; otherwise leave it compiled.
- **Edge cases:** A Release build must compile. Build Release once locally: `xcodebuild … -configuration Release build`.

**WS-33.6 — Documentation**
- **Change:**
  - `ios-cleanup/CLAUDE.md` "On-device data collection (automatic)": rename it "On-device data collection (DEBUG/internal only)". Say that Release writes only the embedding warm cache plus the JSON feedback journal used for queue priority; that `feedback_events`/`training_rows` are written only when `PhotoDuckBuildFlags.collectsMLTrainingData`; and that preferences never change actions or confidence (D-PREFS).
  - `MLTraining/README.md` step 1: collection requires a DEBUG or `PHOTODUCK_ML_COLLECTION` build. Add a section "Required before bundling any model", listing:
    - (1) `suggested_action` vocabulary mismatch;
    - (2) `similarity_to_keeper` NULL in training;
    - (3) `file_size_bytes` = `estimatedFileSize` (now a whole-asset footprint after WS-30) in training vs `max(pixelCount,1)` at inference;
    - (4) training confidence is post-adjustment;
    - (5) `feedback_assets` never written;
    - (6) keeper labels only when the final keeper differs;
    - (7) SCAN-23 (deferred): `PhotoGroup.similarity` score-vs-distance semantics.

    Add a value-level train/serve contract test as a precondition.

### Tests
All in the simulator.
- `PreferenceAdjustedRecommendationTests`:
  - `testSingleKeepBestOnFavoriteGroupDoesNotDowngrade`: favorites {reviewed 1, kept 1}; action, confidence and delete plan unchanged.
  - `testZeroSampleBucketDoesNotDowngrade`: byBucket nearDuplicate {reviewed 3, skipped 3}.
  - `testRejectionHeavyBucketStillOnlyAffectsPriority`: {reviewed 20, accepted 1, rejected 19} → the action stays `.keepBestTrashRest`.
  - `testNarrowKeeperMarginStillDowngrades`: scores 0.90/0.85 → `.reviewManually` (invariant 6).
  - `testPriorityRulesRequireEightDecisions`: screenshots {reviewed 7, deleted 7} → delta 0; {8, 8} → delta > 0.
  - Rewrite `testEditedPhotosDowngradeAggressiveDeleteWhenUserOftenKeepsThem` as `testEditedContentNoLongerAffectsRecommendation`.
  - Extend `testNoActionDependsOnArrayOrdering` to also assert `.keepBestTrashRest`.
- `PhotoFeedbackLearningTests`:
  - `testKeepBestCountsDeletedAssetsNotKeeps`.
  - `testAutoCleanEventsDoNotAffectPreferenceProfile`: new-source events and a legacy-note event.
  - `testManualDeleteOnIneligibleGroupRecordsNilAcceptance`: via `recordSimilarGroupDecision` on a review-only group with `recommendationAccepted: false` passed in; the stored event has `nil`.
  - `testProfileSchemaBumpRebuildsFromRawEvents`: write a v1 profile archive plus raw events and create a new store pair; the profile reflects the events.
  - `testCollectionDisabledWritesNoTrainingRows`: `PhotoMLBridge(store: tempStore, collectsTrainingData: false)`, `persistFeedbackEvents([event])` → `feedbackEventCount() == 0` and `trainingRowCount() == 0`.
  - `testCollectionDisabledStillJournalsFeedback`.
  - Update the three `keptCount` assertions (lines ~115, ~189, ~421) to `deletedCount`/`keptCount == 0`, and explain in the PR.
- `PhotoMLStoreTests`:
  - `testPurgeTrainingCollectionEmptiesTrainingTablesOnly`: features and pairs survive.
  - `testRetentionPurgesTrainingDataWhenCollectionDisabled`.
- `PhotoScanEngineEndToEndTests` (WS-08): `testPreferenceProfileFullOfKeepBestEventsKeepsEligibleGroups`. Inject a profile via WS-08's `preferenceProfileProvider` with favorites/edited/byBucket keepRate 1.0, {accepted 0, rejected 30}. The fixture still emits auto-clean-eligible groups with the same `deleteCandidateIDs` and `reclaimableBytes` as with an empty profile.

### Acceptance criteria
- [ ] After any sequence of Keep Best, Auto-clean or Duck Mode actions, rescanning yields the same eligible groups and reclaim bytes (end-to-end test). Only `preferenceQueuePriority` may differ.
- [ ] The narrow-margin downgrade still applies (test).
- [ ] A Release build compiles with zero warnings, has no `MLGroupActionService` symbol (`nm` or `grep` of the built binary optional; code review of the `#if DEBUG`), and writes no `feedback_events`/`training_rows` (`testCollectionDisabledWritesNoTrainingRows`; device QA on a Release-configuration build).
- [ ] `CLAUDE.md` and `MLTraining/README.md` updated as above.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. Install a **Release-configuration** development build. Do 10 Keep Best and 20 swipes. Download the container (Xcode › Devices › Download Container) and open `Library/Application Support/PhotoDuck/ml/photoduck-ml.sqlite`. `SELECT COUNT(*) FROM training_rows` and `feedback_events` are both 0.

### Pitfalls and out of scope
- Do not touch the keeper ranking or similarity thresholds (WS-39) or the edit signal itself (WS-37). WS-38 owns the identical-copy margin exemption.
- Fire-and-forget SQLite persistence, the single transaction and journal I/O are WS-34. Moving the ML store to Caches and bounding embeddings is WS-46. The `#if DEBUG` export, share sheet and schema-checked DEBUG export are WS-47. PaywallView/privacy copy is WS-48.
- `PhotoFeedbackStore` stays the only writer of the JSON journal. Do not add a second profile path.
- **Reconciliation:** L23. There is a single `collectsTrainingData` gate (compile flag plus runtime check) for WS-46 to reuse, and the group-outcome schema and export are kept. They become DEBUG-only in WS-47 rather than being deleted here.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| ML-04 | confirmed | All mechanisms verified at the cited lines. Extra finding: a `nil` acceptance passed from a view is re-derived in `makeSimilarGroupDecisionEvent` (142-148), so the store also forces `nil` for ineligible groups. Automation uses a new `.autoClean` source, plus the legacy note for old events. |
| SCAN-M01 | confirmed | Same root cause (`keeperAcceptanceRate` 0 at zero samples; the review-only rejection). Its "downgrade after a minimum sample" is superseded by D-PREFS: no action changes at all. Its review-only acceptance fix is adopted. |
| ML-10 | confirmed | Dual writes, the never-written `feedback_assets`, the unused group-action model and the skew are all verified. Two deviations. Tables are still *created* in Release: only writes are gated, plus a one-time purge, to avoid "no such table" in stats and retention. Scan-path `photo_features` metadata cannot be gated here because the same row holds the warm-cache embedding; WS-46 splits them. |
| FSA-17 | confirmed | Latent while no model ships. Documented as a pre-bundling requirement in MLTraining/README, with no code change (D-ML: no model in v1). |

---

## WS-34 — Backup exclusion and feedback I/O

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-33 | no | `ws/34-backup-exclusion-feedback-io` |

**Primary files:** `iOSCleanup/Utilities/PhotoDuckStorage.swift` (*new*), `iOSCleanup/Utilities/SharedHelpers.swift` (diagnostics helper reuse only), `iOSCleanup/iOSCleanupApp.swift`, `iOSCleanup/Engines/PhotoAnalysisCache.swift`, `iOSCleanup/Engines/FileScanEngine.swift`, `iOSCleanup/Utilities/PHAsset+FileSize.swift`, `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Engines/PhotoMLStore.swift`, `iOSCleanup/Engines/PhotoFeedbackStore.swift`, `iOSCleanup/Engines/PhotoPreferenceProfileStore.swift`, `iOSCleanup/Engines/UserKeepDecisionStore.swift` (WS-12), `iOSCleanup/Views/HomeViewModel.swift` (one block removed), `CLAUDE.md`, `iOSCleanupTests/PhotoDuckStorageTests.swift` (*new*), `iOSCleanupTests/PhotoFeedbackLearningTests.swift`, `iOSCleanupTests/PhotoMLStoreTests.swift`, `iOSCleanupTests/DesignLintTests.swift`
**Findings covered:** STORE-09 (P1, confirmed; merged: ML-03 confirmed, BUILD-15 confirmed, FILES-25 confirmed), ML-07 (P2, confirmed), ML-08 (P2, confirmed), FSB-04 (P2, confirmed)
**Decisions applied:**
- D-BACKUP: the whole `Application Support/PhotoDuck` directory is excluded at the directory level at every launch, before any store opens. UserDefaults stays backed up.
- D-ML: SQLite feedback persistence is skipped entirely when collection is off.

### Goal
Nothing PhotoDuck writes under Application Support reaches iCloud or iTunes backups. Review decisions (Keep Best, Delete Selected, swipes) return as soon as PhotoKit succeeds and the JSON journal line is durable. They never wait on the ML actor or on a multi-megabyte archive rewrite. Snapshot saves stop rewriting 8 KB feature rows, and the WAL is truncated after checkpoints.

### Current behavior (verified)
- `iOSCleanup/Utilities/SharedHelpers.swift:1372-1392` `PhotoDuckDiagnosticLog.prepareDirectory`/`applyPrivacyAttributes` sets `isExcludedFromBackup` and `completeUntilFirstUserAuthentication`. This is the **only** `isExcludedFromBackup` in the app (1384). Runtime RT-6 saw the xattr only on `Diagnostics/`.
- Store paths, none excluded:
  - `PhotoMLStore.swift:89-96` (`PhotoDuck/ml`, created in `open()` 101-105);
  - `PhotoAnalysisCache.swift:513-525` (`photo-analysis-cache.json` plus `.backup.json`; `init()` takes no directory);
  - `PHAsset+FileSize.swift:355-366` (`asset-file-sizes-v1.json`);
  - `FileScanEngine.swift:300-311` (`large-video-results.json`);
  - `PhotoFeedbackStore.swift:39-45` and `PhotoPreferenceProfileStore.swift:13-20` (`PhotoDuck/learning`);
  - WS-12 adds `UserKeepDecisionStore` under the same root.
- `iOSCleanup/iOSCleanupApp.swift:12-15` `init()` runs startup cleanup and installs the notification delegate. It prepares no directories.
- `iOSCleanup/Views/HomeViewModel.swift:2003-2016` `saveAnalysisSnapshot(isComplete:)` also calls `mlBridge.makeFeatureRecords(for: photoGroups.flatMap(\.assets), embeddings: [:])` + `persistFeatureRecords` for complete snapshots. Reconcile reaches it after every PhotoKit change (1917). WS-21 replaces that call with `scheduleSnapshot`; the metadata block may remain in whatever save function survives.
- `iOSCleanup/Engines/PhotoMLStore.swift:123-125` sets `journal_mode = WAL`, `synchronous = NORMAL` and `foreign_keys = ON`, but no `journal_size_limit`.
- `iOSCleanup/Engines/PhotoFeedbackStore.swift:51-57` `append(_:)` awaits `persistence.persistFeedbackEvents([event])` before returning, and `:59-66` does the same for batches. `PhotoMLBridge.swift:260-297` inserts the event (autocommit, `PhotoMLStore.swift:947-992`) and then training rows in a **separate** transaction (1059-1071). Callers await this before dismissing: `PhotoGroupDetailView.swift:217-230`, `PhotoResultsView.swift:398-412`.
- `PhotoFeedbackStore.swift:15` `maxStoredRawEvents = 1_000`:
  - `:360-368` `pruneIfNeeded` rebuilds `eventIDs`/`dedupeKeys` from scratch;
  - `:453-462` `markPendingFlush(pruned: true)` calls `compactArchive()` **synchronously**, so at the cap every append re-encodes and atomically rewrites ~1-3 MB;
  - `:479-487` `performFlush` always calls `profileStore.rebuild(from: events)`;
  - `:489-509` `compactArchive`/`save`.

  Existing tests that must keep passing: `testRawEventRetentionPrunesOldEvents` (349) and `testJournalRecoversEventBeforeDelayedArchiveFlush` (430).

### Implementation plan

**WS-34.1 — `PhotoDuckStorage` and directory-level backup exclusion**
- **Why:** Hundreds of MB of regenerable, device-specific data (embeddings, snapshots, size caches, feedback keyed by `localIdentifier`) go into the user's iCloud backup (STORE-09, ML-03, BUILD-15, FILES-25).
- **Change:** new file `iOSCleanup/Utilities/PhotoDuckStorage.swift`:
  ```swift
  enum PhotoDuckStorage {
      /// Application Support/PhotoDuck. Everything under it is regenerable or device-specific (D-BACKUP).
      static func rootURL(fileManager: FileManager = .default) -> URL
      /// Creates the directory, sets isExcludedFromBackup = true and file protection
      /// .completeUntilFirstUserAuthentication. Idempotent; safe to call on every launch and every store init.
      @discardableResult static func prepareDirectory(at url: URL) throws -> URL
      /// Prepares the root once per process (static lock + flag), then `root/components…`.
      static func directory(_ components: String..., fileManager: FileManager = .default) throws -> URL
  }
  ```
  - **These three names are canonical:** `rootURL(fileManager:)`, `prepareDirectory(at:)` and `directory(_:fileManager:)`. There is no `rootDirectory()` or unlabeled `prepareDirectory(_:)`. Later callers use them as written: WS-46 calls `prepareDirectory(at:)` on `Caches/PhotoDuck/ml` (the helper works on any URL, not only under the root), and WS-57/WS-62 call `directory(…)`.
  - Call `try? PhotoDuckStorage.prepareDirectory(at: PhotoDuckStorage.rootURL())` first in `iOSCleanupApp.init()`, before the startup cleanup. This re-applies the flag every launch, which also fixes existing installs.
  - Every store resolves its default directory through `PhotoDuckStorage.directory(…)`, and calls `prepareDirectory(at:)` on an injected directory: `PhotoMLStore.open()` (replace the bare `createDirectory`), `PhotoAnalysisCache` (add `init(directoryURL: URL? = nil)` for tests), `AssetFileSizeRepository` (the write path's `createDirectory`), `LargeVideoResultCache.save`/`remove`, `PhotoFeedbackStore.init`, `PhotoPreferenceProfileStore.init`, and WS-12's `UserKeepDecisionStore`.
  - `PhotoDuckDiagnosticLog.applyPrivacyAttributes` calls `PhotoDuckStorage.prepareDirectory(at:)` instead of duplicating the logic.
  - UserDefaults (entitlement cache, lifetime stats, onboarding, cleanup-state scalars) is untouched and stays backed up. WS-15's `CleanupStateReconciler` handles a restored device with UserDefaults but no snapshot.
  - Add a "Storage & backup" bullet to `ios-cleanup/CLAUDE.md` Key constraints: "Every PhotoDuck store lives under `Application Support/PhotoDuck`, resolved via `PhotoDuckStorage`, which excludes it from backup. New stores must use it."
- **Edge cases:**
  - The flag lives on the directory, so the `.atomic` writes these stores use (replace-by-rename) do not lose it. SQLite `-wal`/`-shm` files are inside the directory.
  - Failures are non-fatal: log them and continue.
  - Do not move anything to Caches here; WS-46 moves the ML store.

**WS-34.2 — Stop metadata re-upserts and bound the WAL (ML-07)**
- **Change:**
  - Delete the `if !groupAssets.isEmpty { … makeFeatureRecords(… embeddings: [:]) … persistFeatureRecords … }` block and its `groupAssets` capture from `saveAnalysisSnapshot`, or from wherever WS-16/WS-21 left the snapshot-save path. The save becomes `await analysisCache.saveSnapshot(snapshot)` followed by the existing `refreshPersistenceHealth()` call. That call is interim: WS-47 deletes `refreshPersistenceHealth()` and every call to it, so add no new callers.
  - In `PhotoMLStore.open()`, add `try execOrThrow("PRAGMA journal_size_limit = 8388608")` right after `journal_mode = WAL`.
  - Add `func journalSizeLimit() throws -> Int { try ensureOpen(); return try queryInt("PRAGMA journal_size_limit") }` for tests.
- **Edge cases:** The scan path still writes features with embeddings (the warm cache). Only the redundant metadata-only upsert goes.

**WS-34.3 — Fire-and-forget SQLite feedback persistence in one transaction (ML-08)**
- **Change (`PhotoFeedbackStore`):**
  - Keep the synchronous journal write (durability for the preference profile).
  - Replace `await persistence.persistFeedbackEvents(…)` in both `append` overloads with `enqueuePersistence(appendedEvents)`, skipped when `!persistence.collectsTrainingData` (WS-33):
    ```swift
    private var persistenceTail: Task<Void, Never>?
    private func enqueuePersistence(_ events: [PhotoReviewFeedbackEvent]) {
        guard persistence.collectsTrainingData, !events.isEmpty else { return }
        let previous = persistenceTail
        persistenceTail = Task(priority: .utility) { [persistence] in
            await previous?.value                       // preserve order
            await persistence.persistFeedbackEvents(events)
        }
    }
    func awaitPendingPersistence() async { await persistenceTail?.value }  // tests and feedbackSummaryLines
    ```
  - `PhotoMLStore` gains `func insertFeedbackEventWithTrainingRows(_ event: FeedbackEventRecord, _ rows: [TrainingRowRecord]) throws`: `BEGIN`, event insert, row inserts, `COMMIT`, with a rollback on error. Refactor the per-row insert into a private helper so it does not open its own transaction. `PhotoMLBridge.persistFeedbackEvent` uses it.
- **Edge cases:**
  - Ordering between events is not semantically required (rows are keyed by event UUID), but the tail keeps it anyway.
  - Keep `insertTrainingRows` for any other caller and its existing test.

**WS-34.4 — Feedback archive I/O at the cap (FSB-04)**
- **Change (`PhotoFeedbackStore`):**
  1. `markPendingFlush(pruned:)` no longer calls `compactArchive()`. Rewrite the comment: crash safety holds because `loadIfNeeded` replays archive plus journal and then `pruneIfNeeded()` drops the same oldest events deterministically.
  2. Incremental prune: `let removed = events.prefix(overflow); events.removeFirst(overflow)`, removing each `removed` event's ID from `eventIDs`. Replace `dedupeKeys: Set<String>` with `dedupeKeyCounts: [String: Int]`: increment on append, decrement on prune, remove at 0. `isDuplicate` checks `dedupeKeyCounts[key] != nil`. This stays correct even if an old archive holds duplicate keys. Set `prunedSinceFlush = true`.
  3. Track `journalLineCount`: the loaded journal count plus the lines appended, reset in `compactArchive()`. When it exceeds 512, call `compactArchive()` from `markPendingFlush`, so a marathon session with no 2 s idle gap still bounds the journal.
  4. Profile updates:
     - `PhotoPreferenceProfileStore` gains a public `func ingest(_ events: [PhotoReviewFeedbackEvent]) async` (private `ingest` for each event, then `save()`);
     - `PhotoFeedbackStore` keeps `pendingProfileEvents` (the survivors of each append);
     - `performFlush`: when `profileDirty`, if `prunedSinceFlush || await profileStore.needsRebuild()`, call `rebuild(from: events)`, else `ingest(pendingProfileEvents)`; then clear both.
  5. Add `#if DEBUG private(set) var archiveWriteCount = 0`, incremented in `save()`, plus `func debugArchiveWriteCount() -> Int`.
- **Edge cases:**
  - `clear()` and `flushPendingWrites()` still compact.
  - A journal-append failure still falls back to an atomic archive write (unchanged).
  - A known, accepted divergence: an event appended after its dedupe twin was pruned can be dropped on crash replay. The keys include a per-decision token, so this is practically impossible. Note it in the PR.

### Tests
All in the simulator.
- `iOSCleanupTests/PhotoDuckStorageTests.swift`:
  - `testPrepareDirectorySetsExcludedFromBackup`: temp directory; `resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true`.
  - `testPrepareDirectoryIsIdempotent`.
  - `testStoreDirectoriesAreExcluded`: for `PhotoMLStore(directoryURL:)` after `open()`, `PhotoFeedbackStore(directoryURL:)`, `PhotoPreferenceProfileStore(directoryURL:)`, `LargeVideoResultCache(directoryURL:)` after `save`, `AssetFileSizeRepository(fileURL:)` after `flush()`, and `PhotoAnalysisCache(directoryURL:)` after `saveSnapshot`, assert the flag on each store's directory.
  - `testExclusionSurvivesAtomicRewrite`: write twice with `.atomic`; the directory flag is still set.
- `PhotoMLStoreTests`:
  - `testJournalSizeLimitIsApplied`: `journalSizeLimit() == 8_388_608`.
  - `testFeedbackEventAndTrainingRowsCommitTogether`: counts +1 and +N after one call.
- `DesignLintTests.testNoFeatureMetadataUpsertFromViews`: no `persistFeatureRecords(` under `Views/`.
- `PhotoFeedbackLearningTests`:
  - `testAppendReturnsBeforeSQLitePersistence`: a stub `PhotoFeedbackPersisting` whose `persistFeedbackEvents` awaits a `CheckedContinuation` held by the test. `append` returns `true`; the journal contains the event; then resume; then `awaitPendingPersistence()`; the stub saw the event.
  - `testDisabledCollectionNeverCallsPersistence`.
  - Update `testBatchDedupePersistsOnlySurvivorToSQLite` to `await feedbackStore.awaitPendingPersistence()` before counting.
  - `testSteadyStateAppendDoesNotRewriteArchive`: `flushDelayNanoseconds` = `UInt64.max / 2`; seed 1,000 events and `flushPendingWrites()`; record `debugArchiveWriteCount()`; append 50 single events; the count is unchanged.
  - `testJournalCompactsAfter512Lines`.
  - `testCrashAfterPruneReplaysToSameNewestWindow`: append 1,050 without flushing; a new store on the same directory → `loadAllEvents().map(\.id)` equals the newest 1,000.
  - `testIncrementalProfileIngestMatchesRebuild`: extends `testRebuildMatchesIncrementalAggregateState`.
  - `testRawEventRetentionPrunesOldEvents` and `testJournalRecoversEventBeforeDelayedArchiveFlush` stay green.

### Acceptance criteria
- [ ] After first launch, `Application Support/PhotoDuck` and every store directory report `isExcludedFromBackup == true` (tests plus device QA).
- [ ] Keep Best and Delete Selected dismiss without awaiting SQLite (test via the suspended stub). At the 1,000-event steady state, a swipe performs one journal append and no archive rewrite (`testSteadyStateAppendDoesNotRewriteArchive`).
- [ ] `journal_size_limit` is 8 MB. No view code upserts feature metadata (tests).
- [ ] The existing retention and journal-recovery tests pass. Zero new warnings. `CLAUDE.md` updated.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. After a full scan of a large library, force an iCloud Backup (Settings › [name] › iCloud › iCloud Backup › Back Up Now). Then check Settings › [name] › iCloud › Manage Account Storage › Backups › This iPhone. PhotoDuck shows a few KB, not hundreds of MB.
2. Instruments › File Activity during 30 swipes at the steady state: no rewrite of `photo-feedback-events.json` except at most one per 2 s idle period or per 512 journal lines.

### Pitfalls and out of scope
- Do not exclude or move UserDefaults. Do not put caches in `tmp`.
- Moving the ML store to `Caches/PhotoDuck/ml`, bounding embeddings, deleting the legacy ML directory and adding `journal_size_limit` to the new DB are WS-46 (chapter 10). The privacy-policy and PaywallView "Local data" copy stating backup exclusion is WS-48.
- The `PhotoAnalysisCache` write-path cost is WS-54. Keep its single-writer/generation invariants (14) untouched. Only its directory resolution changes here.
- **Reconciliation:** the `PhotoDuckStorage` names are fixed as `rootURL`, `prepareDirectory(at:)` and `directory(_:)` (chapter 10 issue: the findings disagreed). `refreshPersistenceHealth()` is interim because WS-47 deletes it.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| STORE-09 | confirmed | The only exclusion is `SharedHelpers.swift:1384` (Diagnostics), and RT-6 agrees. The helper lives in a new `PhotoDuckStorage.swift` (not SharedHelpers) and is applied at the root at launch plus at each store's directory. |
| ML-03 | confirmed | Same evidence, including `learning/`. The PaywallView copy change is deferred to WS-48 (Paywall visuals are frozen; copy is owned there). |
| BUILD-15 | confirmed | Its suggestion to keep feedback and preferences backed up is rejected per D-BACKUP: they are `localIdentifier`-keyed and device-specific. Training gating was done in WS-33. |
| FILES-25 | confirmed | `large-video-results.json` and `asset-file-sizes-v1.json` are not excluded. Covered by the directory flag. |
| ML-07 | confirmed | HomeViewModel.swift:2003-2016 re-upserts group asset metadata on complete saves, reached from reconcile at 1917. No `journal_size_limit` is set (PhotoMLStore.swift:123-125). |
| ML-08 | confirmed | `append` awaits SQLite (PhotoFeedbackStore.swift:51-57), and event and rows use separate transactions (947-992, 1059-1071). Implemented with an ordered tail task, skipped when collection is off. |
| FSB-04 | confirmed | Synchronous compaction on every prune at the cap (453-462), full set rebuilds (360-368) and full profile rebuilds (479-487). One deviation: *any* prune since the last flush triggers a profile rebuild (not only committed ones), so incremental and rebuild results are identical, `totalRawEvents` included. The cost is a small in-memory rebuild, not an archive write. |

---

## WS-35 — Export & Delete completion

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-05, WS-10, WS-11, WS-30 | no | `ws/35-export-delete-completion` |

**Primary files:** `iOSCleanup/Engines/ExternalPhotoExportService.swift`, `iOSCleanup/Engines/ExternalExportArchivePolicy.swift` (*new*), `iOSCleanup/Views/Files/ExternalExportCoordinator.swift`, `iOSCleanup/Views/Export/VerifiedDeletionOffer.swift` (*new*), `iOSCleanup/Views/Export/ExportAlbumView.swift`, `iOSCleanup/Views/Files/LargeVideoExportSummary.swift` (*new*), `iOSCleanup/Views/Files/FileResultsView.swift`, `CLAUDE.md`, `../CLAUDE.md` (outer repo, owner approval required), `iOSCleanupTests/ExternalPhotoExportServiceTests.swift`, `iOSCleanupTests/ExportDeletionOfferTests.swift` (*new*)
**Findings covered:** FILES-09 (P1, confirmed), DEL-15 (P2, confirmed), FILES-10 (P1, confirmed), FILES-11 (P2, confirmed)
**Decisions applied:**
- D-EXPORT-DELETE: deleting originals after a verified export is **free** on both paths. Record this in both CLAUDE.md files. WS-36 later encodes it in `CleanupAccessPolicy`.
- D-UNDO: deletion goes through WS-11's `delete(assets:) -> DeletionResult` (`.deleted(receipt)` / `.declined`). Recovery is Recently Deleted; there is no undo window.

### Goal
An export that may lead to deletion is a faithful archive: the original, any edited render and the adjustment data. Only assets whose manifest entry is archival **and** hash-verified (WS-05) can be offered for deletion. Both export paths (Export Album and Large Videos) end with a verified-delete offer that shows on-device versus iCloud bytes. The system prompt never fires while PhotoDuck is in the background, and a declined prompt leaves a visible "Delete Originals" button. Counts in both summaries always refer to the user's selection.

### Current behavior (verified)
Line numbers are in the current tree, including the uncommitted WIP that WS-01 commits.
- `iOSCleanup/Engines/ExternalPhotoExportService.swift:408-450` `ExternalPhotoExportResourcePolicy.resources(for:available:)` returns **one** resource for videos, ranked `.fullSizeVideo` > `.video` > `.adjustmentBaseVideo`, and every resource for photos. An edited or trimmed video exports only its render, and Export & Delete then removes the original (FILES-09). The test `FileScanEngineTests.swift:853-876` `testExternalVideoExportChoosesOnePlayableResource` pins this.
- `…ExternalPhotoExportService.swift:297-319` `ExternalPhotoExportManifest.AssetEntry` has no export mode. `:1309-1341` `previouslyExportedAssetIDs` accepts any entry whose files are intact. WS-05 replaces the size check with SHA-256 for deletion eligibility.
- `…ExternalPhotoExportService.swift:521-537`: the all-already-exported early return reports `requestedAssetCount: assets.count` (the full selection). `:853-866` `writeAssets` reports `requestedAssetCount: assets.count`, where `assets` is only the pending subset (FILES-11).
- `ExportAlbumView` (currently `Views/HomeView.swift:1369-2068`; WS-10 moves it to `Views/Export/ExportAlbumView.swift`):
  - `:1569-1588` `.onChange(of: scenePhase)` only resumes the Live Activity.
  - `:1931-1951` with `deleteAfterExport`, `deleteExportedOriginals()` runs as soon as a possibly long export finishes, even if the app is backgrounded.
  - `:2013-2037` on user cancellation it returns silently. `exportStatus` still reads "Verified all N items…", and `showPostExportActions` is never shown again (DEL-15).
  - `:2016-2024` it re-checks album membership (all exported IDs must still be in the album).
- `iOSCleanup/Views/Files/FileResultsView.swift:1188-1257` `exportSelectedVideos`:
  - `remainingAssetIDs = explicit − result.exportedAssetIDs` ignores `alreadyExportedAssetIDs` (1200-1202), so re-exported videos read "unfinished" forever;
  - the message ends "The originals remain in Photos." (1221-1233);
  - there is no delete offer (FILES-10). The only deletion is per-row (`deletePhotoLibraryFile`, 1296-1310).

  WS-10 moves orchestration into `ExternalExportCoordinator`, and WS-29 moved idle-timer ownership into `IdleTimerCoordinator`.

### Implementation plan

**WS-35.1 — Archival exports and deletion safety**
- **Why:** Deleting an asset whose export lacks the original or the edit data loses footage and the ability to revert (FILES-09).
- **Change:**
  - New file `iOSCleanup/Engines/ExternalExportArchivePolicy.swift`. Move `ExternalPhotoExportResourcePolicy` here from the service file and change it:
    ```swift
    /// nil in a manifest = written before WS-35.
    enum ExternalPhotoExportMode: String, Codable, Sendable { case archival }

    enum ExternalPhotoExportResourcePolicy {
        /// Every export is archival: every resource PhotoKit lists (original, edited render,
        /// adjustment data, paired video, adjustment bases). DECISION (owner may override).
        /// Operates on WS-05.2's `ExportResource` values.
        static func resources(for asset: PHAsset, available: [ExportResource]) -> [ExportResource] { available }
        static func archivalResourceTypes(_ available: [PHAssetResourceType]) -> [PHAssetResourceType] { available }
    }

    enum ExternalExportDeletionSafety {
        /// Deletion-safe = hash-verified per WS-05 AND archival. Legacy (nil-mode) entries qualify only
        /// when they already contain every resource type the current asset has.
        static func isDeletionSafe(_ entry: ExternalPhotoExportManifest.AssetEntry,
                                   currentResourceTypes: Set<Int>) -> Bool
    }
    ```
    `DECISION (owner may override): every export (copy-only too) is archival; there is no playable-only export in v1, so any later "Delete Originals" is safe without re-exporting.` Delete `preferredVideoResourceIndex` and its test.
  - `AssetEntry` gains `var exportMode: ExternalPhotoExportMode?` (optional; synthesized decode). New entries write `.archival`.
  - In `export(…)`, build `resourceTypesByAssetID` once for the requested assets through WS-05.2's seam, `resourceSource.resources(for:)` (`ExportResourceSource`), so tests use `FakeExportResourceSource`. Do not add a separate resource lister. Then:
    - **The skip set is unchanged (LEAD DECISION, keeping WS-05.7's rule).** `previouslyExportedAssetIDs` keeps WS-05's predicate (intact files, same version via `isSameVersion`). An entry already on the drive is skipped and never re-copied, whether or not it is hashed or archival. Do **not** gate the skip set on `isDeletionSafe`.
    - **Only Export & Delete eligibility uses `isDeletionSafe`.** Narrow WS-05.7's existing `deletionEligibleAssetIDs` in place; do not add a parallel field. It becomes (this run's exported IDs ∩ `recordedAssetIDs`, archival by construction) ∪ (skipped IDs whose entry `isDeletionSafe`). A skipped entry that fails the check (no `sha256`, or missing a resource type the asset now has, such as a legacy render-only edited video) stays out of eligibility. It is reported through WS-05.7's `unverifiedAlreadyExportedAssetIDs`, which widens here to "already on this drive but not verified for deletion", with WS-05.7's existing note ("…can't be verified, so their originals stay in Photos"). WS-35.7 can upgrade hash-less entries by explicit verification.
  - Completion copy on both paths gains "Includes the original and the edited version." when any exported video had more than one video-family resource. Expose `archivedEditedVideoCount` on the result.
- **Edge cases:**
  - Legacy photo entries already hold every resource, so they stay deletion-safe once WS-05's hash rule is met.
  - An unedited legacy video whose only resource is `.video` matches its current types and stays safe.
  - Expected byte totals roughly double for edited videos; the WIP progress text already shows real bytes.

**WS-35.2 — Honest counts on every return path (FILES-11)**
- **Change:** pass `requestedAssetCount: Int` (the original `assets.count` before dedupe) into `writeAssets` and use it in its result. Every return path (early return, normal, cancelled) now reports the user's selection size.

**WS-35.3 — Shared verified-deletion offer**
- **Why:** Both paths need identical safety: explicit verified IDs only, a foreground-only system prompt, and retry after a decline.
- **Change:** new file `iOSCleanup/Views/Export/VerifiedDeletionOffer.swift`:
  ```swift
  struct VerifiedDeletionOffer: Equatable, Sendable {
      let assetIDs: Set<String>          // ⊆ result.deletionEligibleAssetIDs ∩ requested IDs — never widened
      let sizing: ReclaimSizing          // WS-30: device vs iCloud bytes of exactly these assets
      var wasDeclined = false
      static func make(result: ExternalPhotoExportResult, requestedAssetIDs: Set<String>,
                       sizing: (Set<String>) -> ReclaimSizing) -> VerifiedDeletionOffer?  // nil when empty
      var dialogMessage: String          // "Frees about X on this iPhone after you empty Recently Deleted."
                                         // + " Y of them are stored only in iCloud; deleting those frees iCloud storage."
  }
  enum ExportDeletionScheduling {
      enum Decision: Equatable { case commitNow, presentOffer, deferUntilActive, none }
      static func decide(offer: VerifiedDeletionOffer?, deleteRequestedUpFront: Bool,
                         wasCancelled: Bool, isApplicationActive: Bool) -> Decision
  }
  enum VerifiedDeletionOutcome: Equatable { case deleted(DeletionReceipt), declined, albumChanged, failed(String) }
  ```
  - `decide`:
    - no offer → `.none`;
    - not active → `.deferUntilActive`;
    - active and `deleteRequestedUpFront && !wasCancelled` → `.commitNow`;
    - active otherwise → `.presentOffer` (a cancelled run never auto-deletes).
  - `isApplicationActive` is read from `UIApplication.shared.applicationState == .active` on the main actor **at the moment the export returns**. Do not read a SwiftUI `scenePhase` captured by the async task, because it can be stale.
  - `ExternalExportCoordinator` (WS-10) gains:
    - `@Published var deletionOffer: VerifiedDeletionOffer?`;
    - `@Published var pendingDecision: ExportDeletionScheduling.Decision`;
    - `func sceneBecameActive()`, which turns `.deferUntilActive` into `.presentOffer`;
    - `@MainActor func commit(_ offer: VerifiedDeletionOffer, assets: [PHAsset], using deletionManager: DeletionManager) async -> VerifiedDeletionOutcome`. It asserts every asset's ID is in `offer.assetIDs` (DEBUG `precondition`; in Release drop extras and log). It calls `deletionManager.delete(assets:)`, which (WS-11) re-resolves fresh at commit. `.declined` sets `offer.wasDeclined = true` and keeps the offer. `.deleted` clears it. A throw maps to `.failed` and keeps the offer.
  - Sizing: `sizing` is computed from WS-30 data. Large Videos uses `LargeVideoLocalitySummary.make(files: selected verified files)`; Export Album uses the `ReclaimMeasurementController` footprints, else `.unmeasured(estimatedFileSize)`. Pass it in as a closure so the offer stays pure.

**WS-35.4 — Export Album: foreground-only prompt and a persistent retry (DEL-15)**
- **Change (`ExportAlbumView`):**
  - Replace `exportedAssetIDs` with the coordinator's `deletionOffer`. After export, run `ExportDeletionScheduling.decide`:
    - `.commitNow` → `commitVerifiedDeletion()`;
    - `.presentOffer` → `showPostExportActions = true`;
    - `.deferUntilActive` → keep the offer and set `exportStatus = "Export verified. Return to PhotoDuck to delete the originals."`.

    In the existing `.onChange(of: scenePhase)`, `.active` calls `coordinator.sceneBecameActive()` and presents the dialog if needed.
  - `commitVerifiedDeletion()` keeps the album re-check: `assets = exportAlbum.assets.filter { offer.assetIDs.contains($0.localIdentifier) }`; if `assets.count != offer.assetIDs.count`, map to `.albumChanged` (existing copy). Then:
    - `.deleted(receipt)` → `exportAlbum.remove(assetIDs: receipt.assetIDs)` and `exportStatus = "Moved \(receipt.itemCount) originals (≈\(receipt.estimatedBytes.formattedBytes)) to Recently Deleted."`;
    - `.declined` → `exportStatus = "Export verified. Originals were kept — tap Delete Originals to free the space."`.
  - In the action bar, when `deletionOffer != nil && !isExporting`, show a `DuckPrimaryButton` "Delete \(n) Verified Original\(n == 1 ? "" : "s")" that presents the post-export dialog. The dialog's "Delete Originals" calls `commitVerifiedDeletion()`, and its message uses `offer.dialogMessage`. Explicit plural branches only; WS-35 must not depend on WS-31's `CountText`.
  - Copy at ~1784: "Export & Delete copies the original and any edited version, verifies every file, then moves the originals to Recently Deleted." (WS-11 already fixed the undo strings.)
- **Edge cases:**
  - While an offer is pending, starting a new export replaces it. The new run's offer supersedes it.
  - The "Delete N from Photos" (no export) path is unchanged.

**WS-35.5 — Large Videos: verified-delete offer and honest summary (FILES-10, FILES-11)**
- **Change:**
  - New file `iOSCleanup/Views/Files/LargeVideoExportSummary.swift` (pure):
    ```swift
    struct LargeVideoExportSummary: Equatable {
        let requestedIDs: Set<String>; let copiedIDs: Set<String>; let alreadyPresentIDs: Set<String>
        let deletionEligibleIDs: Set<String>                 // ⊆ copied ∪ alreadyPresent
        var verifiedIDs: Set<String> { copiedIDs.union(alreadyPresentIDs) }
        var remainingIDs: Set<String> { requestedIDs.subtracting(verifiedIDs) }
        let title: String; let message: String
        static func make(result: ExternalPhotoExportResult, requestedIDs: Set<String>, destinationName: String,
                         totalBytesText: String) -> LargeVideoExportSummary
    }
    ```
    Messages, with explicit singular/plural branches:
    - all verified: "\(v) videos are on \(drive) (\(c) copied now, \(k) were already there)." — omit the parenthetical when `k == 0` or `c == 0` as appropriate;
    - remaining > 0: append "\(r) couldn't be copied and remain selected so you can retry.";
    - title: "Export Stopped" / "Export Complete with Issues" / "Export Complete".
  - `FileResultsView.exportSelectedVideos` (or the coordinator's result handler after WS-10):
    - use the summary;
    - keep selected **only** `remainingIDs`;
    - build the offer from `deletionEligibleIDs` with `LargeVideoLocalitySummary` sizing;
    - run `decide(…, deleteRequestedUpFront: false, …)`.

    `.presentOffer` shows a `confirmationDialog`:
    - title "Delete \(n) verified video(s) from Photos?";
    - message `offer.dialogMessage`;
    - buttons "Delete \(n) Video(s)" (destructive) and "Keep Originals".

    Commit with `files.filter { offer.assetIDs.contains($0.photoAsset.localIdentifier) }.map(\.photoAsset)`. On `.deleted(receipt)`, add the matching `LargeFile.id`s to `hiddenFileIDs` and call `onAssetDeleted?(id)` for each `receipt.assetIDs` element. On `.declined`, show a persistent header button "Delete \(n) Verified Original(s)" that re-presents the dialog.
  - The completion alert text is `summary.message`, plus "Includes the original and the edited version." when applicable. Remove "The originals remain in Photos."
- **Edge cases:**
  - An iCloud-only video exported with a download (WS-57 later adds a cancellable path) gets iCloud bytes in the dialog, never "frees X on this iPhone".
  - A video deleted elsewhere between export and commit is dropped by WS-11's fresh resolve. The receipt's IDs are the truth.

**WS-35.6 — Documentation (D-EXPORT-DELETE)**
- **Change:**
  - `ios-cleanup/CLAUDE.md`, the Paywall **Free** list: add "deleting originals after a verified Export & Delete (Export Album and Large Videos export)".
  - The `ExportAlbumStore / ExternalPhotoExportService` row becomes "copies every PhotoKit resource (archival: original, edited render, adjustment data), verifies by SHA-256 (WS-05), writes a manifest with `exportMode`; only archival, hash-verified entries are deletion-eligible; the UI offers deletion on both export paths".
  - Workspace `../CLAUDE.md` key invariants: extend the free sentence with "and delete originals after a verified export". The outer repo requires owner approval (README §3, rule 5): ask first, and if there is no approval, put the proposed text in the PR summary. Coordinate wording with WS-36, which rewrites the monetization lines later; do not remove anything WS-11 wrote.

**WS-35.7 — "Verify existing exports" (explicit, opt-in; cuttable)**
- **Why:** The LEAD DECISION keeps WS-05's rule that unhashed exports are skipped and never re-copied. Without an explicit verification step, those originals could never be offered for verified deletion.
- **Change:**
  - `ExternalPhotoExportService.verifyExistingExports(assets: [PHAsset], in dir: URL, allowNetworkAccess: Bool) async throws -> Set<String>`. It runs only for assets whose manifest entry is intact, the same version (`isSameVersion`), lacks `sha256`, and already lists every current resource type (archival completeness). For each resource it streams the asset's bytes through `resourceSource.requestData` into a `SHA256` hasher, and compares the digest and byte count with `ExportFileHasher.sha256Hex(ofFileAt:)` of the on-drive file. When every resource matches, it records the entry with `sha256` filled and `exportMode: .archival` through `ExportManifestStore.appendToJournal`, then `write` (the same durability path as `writeAssets`). It returns the upgraded IDs.
  - It never writes, moves or deletes a media file and never deletes from Photos. A mismatch or a read failure leaves the entry unhashed, and therefore ineligible.
  - UI: when `unverifiedAlreadyExportedAssetIDs` is non-empty after an export, both paths show a text button "Verify \(n) Earlier Export(s)" (explicit plural branches). On success, the returned IDs join the offer's eligible set, and the offer is rebuilt through `VerifiedDeletionOffer.make`. It uses the export's own network setting and the same busy/idle-timer handling as an export run.
- **Tests (`ExternalPhotoExportServiceTests`):** `testVerifyExistingExportsUpgradesMatchingEntry` (the entry gains `sha256`, and the asset becomes deletion-eligible on the next export), `testVerifyExistingExportsLeavesMismatchIneligible`, `testVerifyExistingExportsSkipsIncompleteEntries` (a render-only edited video is never upgraded), and `testVerifyExistingExportsNeverWritesMediaFiles` (the directory listing of media files is unchanged).
- **Cut rule:** if the PR grows past about 1,500 lines, cut this task and record it in `spec/BACKLOG.md`. WS-35.1–35.6 do not depend on it.

### Tests
All in the simulator unless marked.
- `iOSCleanupTests/ExternalPhotoExportServiceTests.swift` (created by WS-05):
  - `testArchivalPolicyKeepsEveryResourceForEditedVideo`: `archivalResourceTypes([.video, .adjustmentData, .fullSizeVideo])` returns all three.
  - `testNewManifestEntriesAreArchival`: with a fake asset registered in WS-05's `FakeExportResourceSource`; skip if WS-05's harness cannot write, and use a pure entry-builder test instead.
  - `testNonDeletionSafeEntryIsSkippedNotRecopied` (LEAD DECISION): a hashed legacy entry holding only `fullSizeVideo` while the asset now lists {video, fullSizeVideo, adjustmentData}. The export skips it (`requestCount` stays 0; it is in `alreadyExportedAssetIDs`), it is **not** in `deletionEligibleAssetIDs`, and it is in `unverifiedAlreadyExportedAssetIDs`.
  - WS-05's `testAlreadyExportedEntryWithoutHashIsSkippedButNotDeletionEligible` stays green unchanged.
  - `testLegacyEditedVideoEntryIsNotDeletionSafe`: an entry with only `fullSizeVideo` against current types {video, fullSizeVideo, adjustmentData} → false.
  - `testLegacyUneditedVideoEntryIsDeletionSafe`: an entry {video} against current {video} → true (given WS-05's hash).
  - `testLegacyPhotoEntryIsDeletionSafe`.
  - `testUnhashedEntryIsNeverDeletionSafe`: relies on the WS-05 rule.
  - `testRequestedAssetCountIsSelectionSizeOnEveryPath`: all-already-exported path via the temp manifest and `ExternalExportTestAsset` with matching signatures → `requestedAssetCount == input`. Mixed path, 3 skipped plus 2 fakes with no resources registered in `FakeExportResourceSource` (they fail "no exportable resources") → `requestedAssetCount == 5`, `alreadyExportedAssetIDs.count == 3`, failures 2.
  - Delete `testExternalVideoExportChoosesOnePlayableResource`.
- `iOSCleanupTests/ExportDeletionOfferTests.swift`:
  - `testOfferContainsOnlyDeletionEligibleRequestedIDs`: failed, unattempted and non-eligible IDs are excluded; the offer never contains an ID outside the request.
  - `testNoOfferWhenNothingEligible`.
  - `testDecideTable`: every combination of upFront, cancelled and active.
  - `testBackgroundCompletionDefersPrompt`.
  - `testCancelledRunNeverCommitsNow`.
  - `testDialogMessageSplitsDeviceAndICloudBytes`.
  - `testSummaryAllAlreadyPresent`: 3 skipped → remaining empty; the message mentions "already there".
  - `testSummaryMixed`: 3 skipped plus 2 copied → "5 videos are on …"; remaining empty.
  - `testSummaryPartialFailureKeepsOnlyFailedSelected`.
  - `testSummarySingularWording`.
- **Device only:** the background prompt behavior and the system dialog (Device QA).

### Acceptance criteria
- [ ] Every export writes archival entries (`exportMode: "archival"`), and edited videos produce the original plus the render plus adjustment data on the drive (test plus device QA).
- [ ] Only archival, hash-verified asset IDs from the user's request are ever passed to `DeletionManager.delete(assets:)` (tests). The album is re-checked before Export Album deletion.
- [ ] The Large Videos export offers a verified delete with on-device versus iCloud bytes. One confirmation plus one system prompt moves exactly those originals to Recently Deleted (device QA).
- [ ] The system prompt never fires while backgrounded. After a decline, a "Delete N Verified Originals" button is visible on both paths (tests plus device QA).
- [ ] `requestedAssetCount` equals the selection on every path. Re-exporting already-present videos reports success with nothing remaining (tests).
- [ ] Entries already on the drive are skipped and never re-copied, whatever their hash or archival state. Only `isDeletionSafe` entries are deletion-eligible (`testNonDeletionSafeEntryIsSkippedNotRecopied`).
- [ ] The nested CLAUDE.md records D-EXPORT-DELETE. The `../CLAUDE.md` change is applied with owner approval or proposed in the PR. Zero new warnings.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. Trim a 4K video in Photos (non-destructive edit). Add it to the Export Album. Export & Delete to a USB SSD. The drive contains the original `.MOV`, the `FullSizeRender` and the adjustment plist. The original is in Recently Deleted only after you confirm the system prompt.
2. Start Export & Delete of about 20 GB and switch apps before the last file. On return, the delete dialog appears (no prompt fired while away). Decline the system prompt. Status says "Originals were kept", and "Delete N Verified Originals" is visible. Tap it; the prompt appears again.
3. Large Videos: select 3 videos, export, and get the offer. Confirm. Rows disappear, and the Home "Sent to Recently Deleted" ledger increases (WS-32).
4. Re-export the same 3 videos. The alert says they are already on the drive, nothing stays selected, and the offer is available.

### Pitfalls and out of scope
- `ExternalPhotoExportService` WIP is committed by WS-01, and WS-05 is the first to restructure it. Rebase on WS-05 and do not redo its hashing, partial-file identity, manifest journal or migration work.
- ENOSPC/EFBIG handling, capacity preflight, cancellable downloads and resume banners are WS-57 (chapter 12). Idle timer ownership is WS-29's `IdleTimerCoordinator`; do not reintroduce `isIdleTimerDisabled` here.
- Paid gating of "Delete N from Photos" without export and of large-video multi-delete is WS-36/WS-42. Verified deletion after export stays free (D-EXPORT-DELETE).
- Never widen the offer's ID set (for example to "all selected"), and never infer IDs from array positions (invariants 1 and 24).
- **Reconciliation:**
  - LEAD DECISION: "skip re-copy" and "deletion-eligible" stay separate. WS-05's skip rule is unchanged, so a legacy or non-archival entry is never re-exported. Only `deletionEligibleAssetIDs` is narrowed by `isDeletionSafe`. The earlier plan to re-export legacy playable-only entries is dropped, and WS-35.7 adds the explicit verification path.
  - WS-05's actual seams are used: `ExportResourceSource`/`FakeExportResourceSource` instead of a new lister, the existing `deletionEligibleAssetIDs` narrowed rather than a parallel field, and `ExportManifestStore` for entry upgrades.
  - `../CLAUDE.md` is the outer repo, so it needs owner approval (README §3 rule 5), with the same wording as WS-36.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FILES-09 | confirmed | The single-resource video policy is at ExternalPhotoExportService.swift:408-450, and the album copy promises verified deletion (HomeView.swift:1784). One deviation: there is **no** `playableOnly` mode (DECISION: all exports archival). Legacy entries are judged by resource-type completeness, not a two-mode flag, which keeps unedited legacy videos and photos deletion-safe without re-copying once they are hash-verified (WS-05, or WS-35.7's explicit pass). Incomplete legacy entries are skipped, never re-copied and never deletion-eligible (LEAD DECISION). |
| DEL-15 | confirmed | The code facts are verified (HomeView.swift:1931-1951, 2013-2037). Exactly what PhotoKit returns when asked to delete from the background is device-dependent; the fix (defer until active, persistent retry) is safe either way. It uses `UIApplication.applicationState` instead of a captured `scenePhase`. |
| FILES-10 | confirmed | There is no delete offer after the Large Videos export (FileResultsView.swift:1221-1257). Free per D-EXPORT-DELETE. It uses WS-11's `delete(assets:)`; the finding's "10-second undo" wording is obsolete (D-UNDO). |
| FILES-11 | confirmed | `remaining` ignores `alreadyExportedAssetIDs` (1200-1202), and `writeAssets` reports the pending count (853-866). Fixed in both places with the pure `LargeVideoExportSummary`. |
