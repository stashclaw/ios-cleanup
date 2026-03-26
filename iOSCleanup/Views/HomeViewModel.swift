import Foundation
import SwiftUI
import Photos
import Contacts
import CoreImage
import CoreImage.CIFilterBuiltins
@preconcurrency import Vision

// MARK: - Cache types (Codable surrogates for PHAsset-bearing models)

private extension PhotoGroup.SimilarityReason {
    var cacheKey: String {
        switch self {
        case .nearDuplicate:   return "nearDuplicate"
        case .exactDuplicate:  return "exactDuplicate"
        case .visuallySimilar: return "visuallySimilar"
        case .burstShot:       return "burstShot"
        }
    }
    init?(cacheKey: String) {
        switch cacheKey {
        case "nearDuplicate":   self = .nearDuplicate
        case "exactDuplicate":  self = .exactDuplicate
        case "visuallySimilar": self = .visuallySimilar
        case "burstShot":       self = .burstShot
        default: return nil
        }
    }
}

private struct CachedPhotoGroup: Codable {
    let id: UUID
    let localIdentifiers: [String]
    let similarity: Float
    let reasonKey: String
}

private struct CachedLargeFile: Codable {
    let id: UUID
    let sourceType: String      // "photoLibrary" | "filesystem"
    let localIdentifier: String?
    let urlString: String?
    let displayName: String
    let byteSize: Int64
    let creationDate: Date?
}

private struct ScanResultsCache: Codable {
    let version: Int
    let savedAt: Date
    let photoGroups: [CachedPhotoGroup]
    let largeFiles: [CachedLargeFile]
    var blurPhotoIds: [String]
    var screenshotPhotoIds: [String]
    /// Parallel arrays: large photo asset IDs and their recorded file sizes.
    var largePhotoIds:   [String]
    var largePhotoSizes: [Int64]

    // Custom init provides defaults for optional fields so old cache files decode cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version            = try c.decode(Int.self,                forKey: .version)
        savedAt            = try c.decode(Date.self,               forKey: .savedAt)
        photoGroups        = try c.decode([CachedPhotoGroup].self, forKey: .photoGroups)
        largeFiles         = try c.decode([CachedLargeFile].self,  forKey: .largeFiles)
        blurPhotoIds       = (try? c.decode([String].self,         forKey: .blurPhotoIds))       ?? []
        screenshotPhotoIds = (try? c.decode([String].self,         forKey: .screenshotPhotoIds)) ?? []
        largePhotoIds      = (try? c.decode([String].self,         forKey: .largePhotoIds))      ?? []
        largePhotoSizes    = (try? c.decode([Int64].self,          forKey: .largePhotoSizes))    ?? []
    }

    init(version: Int, savedAt: Date, photoGroups: [CachedPhotoGroup],
         largeFiles: [CachedLargeFile], blurPhotoIds: [String], screenshotPhotoIds: [String],
         largePhotoIds: [String], largePhotoSizes: [Int64]) {
        self.version            = version
        self.savedAt            = savedAt
        self.photoGroups        = photoGroups
        self.largeFiles         = largeFiles
        self.blurPhotoIds       = blurPhotoIds
        self.screenshotPhotoIds = screenshotPhotoIds
        self.largePhotoIds      = largePhotoIds
        self.largePhotoSizes    = largePhotoSizes
    }
}

// MARK: - Thread-safe, deduplicating accumulator for photo groups

private actor PhotoGroupCollector {
    // Keyed by canonical asset-ID set; always keeps the highest-priority reason.
    private var canonical: [Set<String>: PhotoGroup] = [:]

    /// Pre-populate with existing cached groups so incremental merges don't lose prior results.
    func seed(_ groups: [PhotoGroup]) {
        for group in groups {
            let key = Set(group.assets.map(\.localIdentifier))
            canonical[key] = group
        }
    }

    private func priority(_ r: PhotoGroup.SimilarityReason) -> Int {
        switch r {
        case .exactDuplicate:  return 3
        case .nearDuplicate:   return 2
        case .burstShot:       return 1
        case .visuallySimilar: return 0
        }
    }

    func merge(_ incoming: [PhotoGroup]) -> [PhotoGroup] {
        for group in incoming {
            let key = Set(group.assets.map(\.localIdentifier))
            if let existing = canonical[key] {
                if priority(group.reason) > priority(existing.reason) {
                    canonical[key] = PhotoGroup(
                        id: existing.id,
                        assets: existing.assets,
                        similarity: existing.similarity,
                        reason: group.reason
                    )
                }
            } else {
                canonical[key] = group
            }
        }
        return Array(canonical.values)
    }
}

// MARK: - ViewModel

// MARK: - Library change observer trampoline

private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    weak var viewModel: HomeViewModel?
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak viewModel] in
            viewModel?.handleLibraryChange(changeInstance)
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject, @unchecked Sendable {

    enum ScanState: Equatable {
        case idle, scanning, done, failed(String)
    }

    @Published var photoScanState:      ScanState = .idle
    @Published var fileScanState:       ScanState = .idle
    @Published var blurScanState:       ScanState = .idle
    @Published var screenshotScanState: ScanState = .idle
    @Published var largePhotoScanState: ScanState = .idle
    @Published var contactScanState:        ScanState = .idle
    @Published var semanticScanState:       ScanState = .idle
    @Published var eventRollScanState:      ScanState = .idle
    @Published var videoDuplicateScanState: ScanState = .idle
    @Published var smartPicksScanState:     ScanState = .idle

    @Published var smartPicks: [PHAsset] = []
    /// Reason a photo was flagged as a wasted shot (keyed by localIdentifier).
    /// Only set for photos added via wasted-shot detection, not quality-score candidates.
    @Published var smartPicksReasons: [String: WastedReason] = [:]

    @Published var duplicateProgress:   (completed: Int, total: Int) = (0, 0)
    @Published var similarProgress:     (completed: Int, total: Int) = (0, 0)
    @Published var blurProgress:        (completed: Int, total: Int) = (0, 0)
    @Published var largePhotoProgress:  (completed: Int, total: Int) = (0, 0)
    @Published var scanStartTime: Date? = nil

    @Published var photoGroups:          [PhotoGroup]      = []
    @Published var contactMatches:       [ContactMatch]    = []
    @Published var largeFiles:           [LargeFile]       = []
    @Published var blurPhotos:           [PHAsset]         = []
    @Published var screenshotAssets:     [PHAsset]         = []
    @Published var largePhotos:          [LargePhotoItem]  = []
    @Published var semanticGroups:       [SemanticGroup]   = []
    @Published var eventRolls:           [EventRoll]       = []
    @Published var videoGroups:          [VideoGroup]      = []
    @Published var recentlyDeletedPhotos:[PHAsset]         = []
    @Published var recentlyDeletedBytes: Int64        = 0
    @Published var recentlyDeletedScanState: ScanState = .idle

    /// Photo-library breakdown for the segmented storage donut.
    @Published var photoLibraryBytes: Int64 = 0   // image assets only
    @Published var videoLibraryBytes: Int64 = 0   // video assets only

    /// Persistent cumulative count of bytes freed across all sessions.
    @Published var totalBytesFreed: Int64 = 0
    private let totalBytesFreedKey = "photoduck.totalBytesFreed"

    /// Persistent cumulative count of photos/videos deleted across all sessions.
    @Published var totalPhotosDeleted: Int = 0
    private let totalPhotosDeletedKey = "photoduck.totalPhotosDeleted"

    /// Flat set of asset localIdentifiers belonging to reviewed (completed, skipped, or queued)
    /// groups. Used for O(1) per-asset lookups in HomeView chip counts — avoids expensive
    /// sort+join per render that would freeze the UI during a live scan.
    @Published private(set) var reviewedAssetIDs: Set<String> = []

    func refreshReviewedGroupKeys() {
        let completedKeys   = Set(UserDefaults.standard.stringArray(forKey: "GroupReview_completedGroups") ?? [])
        let skippedGroupKeys = Set(UserDefaults.standard.stringArray(forKey: GroupReviewViewModel.skippedKey) ?? [])
        let markedIDs       = Set(UserDefaults.standard.stringArray(forKey: "GroupReview_markedIDs") ?? [])

        // Start with directly-marked asset IDs, then add all assets from completed/skipped groups.
        // groupKey computation happens here once — not on every HomeView render.
        var assetIDs = markedIDs
        for group in photoGroups {
            let key = GroupReviewViewModel.groupKey(for: group)
            if completedKeys.contains(key) || skippedGroupKeys.contains(key) {
                group.assets.forEach { assetIDs.insert($0.localIdentifier) }
            }
        }
        reviewedAssetIDs = assetIDs
    }

    /// Rotated at the start of each scan. Callbacks that carry a stale ID are dropped,
    /// preventing results from an old scan from polluting a new one.
    private var photoScanId      = UUID()
    private var fileScanId       = UUID()
    private var blurScanId       = UUID()
    private var screenshotScanId = UUID()
    private var largePhotoScanId = UUID()
    private var contactScanId          = UUID()
    private var semanticScanId         = UUID()
    private var eventRollScanId        = UUID()
    private var videoDuplicateScanId   = UUID()

    @Published var lastScanDate: Date? = nil
    @Published var scanRanThisSession: Bool = false
    /// Set to true when the photo library adds new assets after the last scan.
    /// HomeView uses this to show a "New photos detected" nudge.
    @Published var libraryChangedSinceLastScan: Bool = false

    // MARK: - Initial-scan loading screen
    /// false until either (a) valid cache is loaded or (b) Tier 1+2 engines complete.
    /// HomeView shows an opaque loading overlay while this is false.
    @Published var isInitialScanReady: Bool = false
    /// 0.0 → 1.0 progress for the loading screen.
    @Published var initialScanProgress: Double = 0
    /// Human-readable phase shown under the progress bar.
    @Published var initialScanPhase: String = "Starting up…"

    private let libraryObserver = LibraryChangeObserver()

    /// Total count of ALL assets in the photo library (photos + videos + screenshots).
    @Published var totalLibraryCount: Int = 0

    // MARK: - Metadata category counts (predicate-based, no scan needed)

    @Published var panoramaCount:    Int = 0
    @Published var portraitModeCount: Int = 0
    @Published var livePhotoCount:   Int = 0

    /// Flat asset arrays for metadata categories (populated by fetchMetadataCounts).
    @Published var panoramaAssets:    [PHAsset] = []
    @Published var portraitModeAssets: [PHAsset] = []
    @Published var livePhotoAssets:   [PHAsset] = []

    /// Fetches assets for all three metadata categories using subtype predicates.
    /// Fast — no image decoding, pure PHFetchResult enumeration.
    func fetchMetadataAssets() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let (pano, portrait, live) = await Task.detached(priority: .utility) {
            // Panoramas
            let panoOpts = PHFetchOptions()
            panoOpts.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0",
                                             PHAssetMediaSubtype.photoPanorama.rawValue)
            var panoAssets: [PHAsset] = []
            PHAsset.fetchAssets(with: .image, options: panoOpts)
                .enumerateObjects { asset, _, _ in panoAssets.append(asset) }

            // Portrait Mode (depth effect)
            let portraitOpts = PHFetchOptions()
            portraitOpts.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0",
                                                  PHAssetMediaSubtype.photoDepthEffect.rawValue)
            var portraitAssets: [PHAsset] = []
            PHAsset.fetchAssets(with: .image, options: portraitOpts)
                .enumerateObjects { asset, _, _ in portraitAssets.append(asset) }

            // Live Photos
            let liveOpts = PHFetchOptions()
            liveOpts.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0",
                                              PHAssetMediaSubtype.photoLive.rawValue)
            var liveAssets: [PHAsset] = []
            PHAsset.fetchAssets(with: .image, options: liveOpts)
                .enumerateObjects { asset, _, _ in liveAssets.append(asset) }

            return (panoAssets, portraitAssets, liveAssets)
        }.value

        panoramaAssets     = pano
        panoramaCount      = pano.count
        portraitModeAssets = portrait
        portraitModeCount  = portrait.count
        livePhotoAssets    = live
        livePhotoCount     = live.count
    }

    init() {
        totalBytesFreed    = Int64(UserDefaults.standard.integer(forKey: totalBytesFreedKey))
        totalPhotosDeleted = UserDefaults.standard.integer(forKey: totalPhotosDeletedKey)
        // loadCache() runs off-main so JSON decode + PHAsset fetch don't block first frame.
        // autoScanOnLaunch waits for it to finish before deciding whether to scan.
        NotificationCenter.default.addObserver(
            forName: .didFreeBytes, object: nil, queue: .main
        ) { [weak self] note in
            if let bytes = note.userInfo?["bytes"] as? Int64, bytes > 0 {
                Task { @MainActor [weak self] in self?.addBytesFreed(bytes) }
            }
            if let count = note.userInfo?["count"] as? Int, count > 0 {
                Task { @MainActor [weak self] in self?.addPhotosDeleted(count) }
            }
            Task { @MainActor [weak self] in self?.refreshReviewedGroupKeys() }
        }
        refreshReviewedGroupKeys()
        libraryObserver.viewModel = self
        PHPhotoLibrary.shared().register(libraryObserver)
        // Single coordinator — handles cache load, metadata refresh, and tiered engine scan.
        Task(priority: .utility) { await autoScanOnLaunch() }
    }

    /// Single launch coordinator. Runs entirely on a utility task (never blocks the main thread).
    ///
    /// Flow:
    ///  1. Load cache off-main → UI shows cached results immediately
    ///  2. Refresh metadata counts in parallel (library count, donut, metadata cards)
    ///  3. If cache is fresh → done (no scan needed)
    ///  4. Otherwise run engines in 3 tiers so fast results appear first:
    ///     Tier 1 (PHFetch only, ~200 ms) → Tier 2 (blur/dHash, 1–3 s) → Tier 3 (Vision/ML, background)
    private func autoScanOnLaunch() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            isInitialScanReady = true   // no permission — skip loading screen
            return
        }

        // ── Step 1: load cache off the main thread ─────────────────────────
        initialScanPhase    = "Loading saved results…"
        initialScanProgress = 0.05
        await Task.detached(priority: .userInitiated) { [weak self] in
            await self?.loadCacheOffMain()
        }.value

        // ── Step 2: kick off metadata/storage in the background (non-blocking) ──
        // These only feed the donut chart and metadata cards — they must NOT gate
        // the loading screen. fetchStorageBreakdown() enumerates every asset's KVC
        // fileSize and can take 30 s+ on large libraries; running it in parallel
        // with the engine tiers is fine.
        Task(priority: .utility)    { await self.refreshTotalLibraryCount() }
        Task(priority: .utility)    { await self.fetchMetadataAssets() }
        Task(priority: .background) { await self.fetchStorageBreakdown() }

        // ── Step 3: reveal the app immediately — never block the user ─────
        // Whether cache exists or not, open HomeView right now.
        // Scans stream results into cards in the background.
        isInitialScanReady = true

        let hasCachedData = !photoGroups.isEmpty || !blurPhotos.isEmpty || !screenshotAssets.isEmpty
        if hasCachedData && !libraryChangedSinceLastScan { return }

        // ── Step 4: first launch / library changed — tiered background scan ─
        // All tiers run silently. Cards update as results arrive.

        // Tier 1: pure PHFetch / FileManager — completes in ~200 ms
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.scanScreenshots() }
            group.addTask { await self.scanFiles() }
            group.addTask { await self.scanLargePhotos() }
        }

        // Tier 2: Laplacian blur + dHash duplicates
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.scanBlur() }
            group.addTask { await self.scanPhotos() }
        }

        // Tier 3: heavy Vision / ML / geocoder at background priority
        await Task(priority: .background) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.scanSemantic() }
                group.addTask { await self.scanEventRolls() }
            }
        }.value
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(libraryObserver)
    }

    // MARK: - PHPhotoLibraryChangeObserver

    func handleLibraryChange(_ changeInstance: PHChange) {
        // Only care about inserted assets — our own deletes are tracked locally.
        let imageResult = PHAsset.fetchAssets(with: .image, options: nil)
        let videoResult = PHAsset.fetchAssets(with: .video, options: nil)
        let hasInserts = changeInstance.changeDetails(for: imageResult)?.insertedObjects.isEmpty == false
            || changeInstance.changeDetails(for: videoResult)?.insertedObjects.isEmpty == false
        guard hasInserts else { return }
        guard lastScanDate != nil else { return }  // no scan yet — nothing to invalidate
        libraryChangedSinceLastScan = true
        // Invalidate the scan cache so the next manual scan starts fresh.
        try? FileManager.default.removeItem(at: cacheURL)
        // Refresh cheap metadata (counts, donut).
        Task { await refreshTotalLibraryCount() }
        Task { await fetchMetadataAssets() }
    }

    /// Scans PHAssetResource file sizes for all images and videos to populate
    /// `photoLibraryBytes` and `videoLibraryBytes` used by the segmented donut chart.
    /// Enumeration runs off the main thread to avoid blocking UI on large libraries.
    func fetchStorageBreakdown() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let (photos, videos) = await Task.detached(priority: .utility) {
            var photos: Int64 = 0
            var videos: Int64 = 0

            // Images
            let imageResult = PHAsset.fetchAssets(with: .image, options: nil)
            imageResult.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                for resource in resources {
                    if resource.type == .photo || resource.type == .fullSizePhoto {
                        if let size = resource.value(forKey: "fileSize") as? Int64 {
                            photos += size
                            break
                        }
                    }
                }
            }

            // Videos
            let videoResult = PHAsset.fetchAssets(with: .video, options: nil)
            videoResult.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                for resource in resources {
                    if resource.type == .video || resource.type == .fullSizeVideo {
                        if let size = resource.value(forKey: "fileSize") as? Int64 {
                            videos += size
                            break
                        }
                    }
                }
            }

            return (photos, videos)
        }.value

        self.photoLibraryBytes = photos
        self.videoLibraryBytes = videos
    }

    /// Fetches the real library size across all media types (no filters).
    func refreshTotalLibraryCount() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let count = await Task.detached(priority: .utility) {
            PHAsset.fetchAssets(with: .image, options: nil).count +
            PHAsset.fetchAssets(with: .video, options: nil).count
        }.value
        totalLibraryCount = count
    }

    // MARK: - Computed

    var reclaimableBytes: Int64 {
        let fileSum = largeFiles.reduce(Int64(0)) { total, file in
            switch file.source {
            case .filesystem:
                return total + file.byteSize
            case .photoLibrary(let asset):
                // Only count videos actually stored on-device; iCloud-only videos
                // occupy zero local storage and cannot be "reclaimed" locally.
                return total + Self.locallyStoredBytes(asset: asset, storedSize: file.byteSize)
            }
        }
        // Blur photos: estimate ~3 MB per photo (average iPhone JPEG)
        let blurSum       = Int64(blurPhotos.count) * 3_000_000
        // Screenshots average ~200 KB each on modern iOS
        let screenshotSum = Int64(screenshotAssets.count) * 200_000
        // Large photos: use exact sizes since LargePhotoScanEngine records them
        let largePhotoSum = largePhotos.reduce(Int64(0)) { $0 + $1.byteSize }
        // Junk cannot logically exceed what is actually used on the device
        return min(fileSum + blurSum + screenshotSum + largePhotoSum, max(0, storageUsedBytes))
    }

    /// Returns `storedSize` if the primary resource is physically on-device, 0 otherwise.
    private static func locallyStoredBytes(asset: PHAsset, storedSize: Int64) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let primaryType: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        guard let resource = resources.first(where: { $0.type == primaryType }) ?? resources.first
        else { return 0 }
        let isLocal = (resource.value(forKey: "locallyAvailable") as? Bool) ?? false
        return isLocal ? storedSize : 0
    }
    var reclaimableFormatted: String {
        ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
    }
    var totalBytesFreedFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalBytesFreed, countStyle: .file)
    }
    func addBytesFreed(_ bytes: Int64) {
        totalBytesFreed += bytes
        UserDefaults.standard.set(Int(min(totalBytesFreed, Int64(Int.max))), forKey: totalBytesFreedKey)
    }
    func addPhotosDeleted(_ count: Int) {
        totalPhotosDeleted += count
        UserDefaults.standard.set(totalPhotosDeleted, forKey: totalPhotosDeletedKey)
    }
    var hasAnyResult: Bool {
        !photoGroups.isEmpty || !largeFiles.isEmpty || !blurPhotos.isEmpty
            || !screenshotAssets.isEmpty || !largePhotos.isEmpty
    }

    var isSemanticVisible: Bool {
        switch semanticScanState {
        case .scanning: return true
        case .done:     return !semanticGroups.isEmpty
        default:        return false
        }
    }

    var isAnyScanning: Bool {
        [photoScanState, fileScanState, blurScanState, screenshotScanState, largePhotoScanState,
         contactScanState, semanticScanState, eventRollScanState].contains {
            if case .scanning = $0 { return true }; return false
        }
    }
    var isAllDone: Bool {
        [photoScanState, fileScanState, blurScanState, screenshotScanState, largePhotoScanState,
         contactScanState, semanticScanState, eventRollScanState].allSatisfy {
            if case .done = $0 { return true }; return false
        }
    }

    var overallProgressFraction: Double {
        let total     = duplicateProgress.total + similarProgress.total + blurProgress.total
        guard total > 0 else { return 0 }
        let completed = duplicateProgress.completed + similarProgress.completed + blurProgress.completed
        return Double(completed) / Double(total)
    }

    // MARK: - Storage usage

    var storageUsedFraction: Double {
        guard storageTotalBytes > 0 else { return 0 }
        return Double(storageUsedBytes) / Double(storageTotalBytes)
    }
    var storageUsedFormatted: String {
        ByteCountFormatter.string(fromByteCount: storageUsedBytes, countStyle: .file) + " used"
    }
    var storageTotalFormatted: String {
        ByteCountFormatter.string(fromByteCount: storageTotalBytes, countStyle: .file) + " total"
    }
    /// Uses URL resource values so "available" matches what iOS Settings shows
    /// (includes purgeable iCloud cache — systemFreeSize alone is too conservative).
    var storageCapacity: (total: Int64, available: Int64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
        let total = values.volumeTotalCapacity,
        let avail = values.volumeAvailableCapacityForImportantUsage {
            return (Int64(total), Int64(avail))
        }
        // Fallback (less accurate on iCloud-heavy devices)
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (attrs?[.systemSize] as? Int64) ?? 0
        let free  = (attrs?[.systemFreeSize] as? Int64) ?? 0
        return (total, free)
    }
    private var storageUsedBytes: Int64 {
        let cap = storageCapacity
        return max(0, cap.total - cap.available)
    }
    private var storageTotalBytes: Int64 {
        storageCapacity.total
    }

    // MARK: - Scans

    func scanPhotos() async {
        let currentId = UUID()
        photoScanId = currentId

        // Incremental if we already have cached results — only scan photos added since last scan.
        let addedAfter: Date? = lastScanDate.flatMap { photoGroups.isEmpty ? nil : $0 }

        photoScanState    = .scanning
        duplicateProgress = (0, 0)
        similarProgress   = (0, 0)
        scanStartTime     = Date()
        scanRanThisSession = true
        libraryChangedSinceLastScan = false
        if addedAfter == nil { photoGroups = [] }  // full scan: clear; incremental: keep & merge

        // Seed the collector with any already-cached groups so incremental merges correctly.
        let collector = PhotoGroupCollector()
        if addedAfter != nil { await collector.seed(photoGroups) }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let engine = PhotoScanEngine()
                for await result in engine.scan() {
                    guard await self.photoScanId == currentId else { return }
                    if case .success(let groups) = result {
                        let filtered = groups.filter { $0.reason == .nearDuplicate || $0.reason == .burstShot }
                        let snapshot = await collector.merge(filtered)
                        await MainActor.run {
                            guard self.photoScanId == currentId else { return }
                            self.photoGroups = snapshot
                        }
                    }
                }
            }
            group.addTask {
                let engine = DuplicateHashEngine()
                do {
                    for try await event in engine.scan(addedAfter: addedAfter) {
                        guard await self.photoScanId == currentId else { return }
                        switch event {
                        case .progress(let c, let t):
                            await MainActor.run {
                                guard self.photoScanId == currentId else { return }
                                self.duplicateProgress = (c, t)
                            }
                        case .duplicatesFound(let groups):
                            let snapshot = await collector.merge(groups)
                            await MainActor.run {
                                guard self.photoScanId == currentId else { return }
                                self.photoGroups = snapshot
                                if self.duplicateProgress.total > 0 {
                                    self.duplicateProgress = (self.duplicateProgress.total,
                                                              self.duplicateProgress.total)
                                }
                            }
                        }
                    }
                } catch {}
            }
            group.addTask {
                let engine = SimilarityEngine()
                do {
                    for try await event in engine.scan(addedAfter: addedAfter) {
                        guard await self.photoScanId == currentId else { return }
                        switch event {
                        case .progress(let c, let t):
                            await MainActor.run {
                                guard self.photoScanId == currentId else { return }
                                self.similarProgress = (c, t)
                            }
                        case .groupsFound(let groups):
                            let snapshot = await collector.merge(groups)
                            await MainActor.run {
                                guard self.photoScanId == currentId else { return }
                                self.photoGroups = snapshot
                                if self.similarProgress.total > 0 {
                                    self.similarProgress = (self.similarProgress.total,
                                                            self.similarProgress.total)
                                }
                            }
                        }
                    }
                } catch {}
            }
        }

        guard photoScanId == currentId else { return }

        // Strip assets already in an exactDuplicate group from visuallySimilar groups.
        // Prevents the same photo pair appearing in both Duplicates and Similar categories.
        let exactIds = Set(photoGroups
            .filter { $0.reason == .exactDuplicate }
            .flatMap { $0.assets.map(\.localIdentifier) })
        if !exactIds.isEmpty {
            photoGroups = photoGroups.compactMap { group -> PhotoGroup? in
                guard group.reason == .visuallySimilar else { return group }
                let filtered = group.assets.filter { !exactIds.contains($0.localIdentifier) }
                guard filtered.count >= 2 else { return nil }
                return PhotoGroup(id: group.id, assets: filtered, similarity: group.similarity, reason: group.reason)
            }
        }

        photoScanState = .done
        saveCache()

        // Kick off Smart Picks computation if we have material from either scan
        if !blurPhotos.isEmpty || !photoGroups.isEmpty {
            Task { await self.computeSmartPicks() }
        }
    }

    func scanScreenshots() async {
        let currentId = UUID()
        screenshotScanId    = currentId
        screenshotScanState = .scanning
        let addedAfter: Date? = lastScanDate.flatMap { screenshotAssets.isEmpty ? nil : $0 }
        if addedAfter == nil { screenshotAssets = [] }

        let engine = ScreenshotScanEngine()
        do {
            for try await event in engine.scan(addedAfter: addedAfter) {
                guard screenshotScanId == currentId else { return }
                switch event {
                case .screenshotsFound(let newAssets):
                    // Incremental: append new assets, avoiding duplicates.
                    if addedAfter != nil {
                        let existingIDs = Set(screenshotAssets.map(\.localIdentifier))
                        screenshotAssets += newAssets.filter { !existingIDs.contains($0.localIdentifier) }
                    } else {
                        screenshotAssets = newAssets
                    }
                }
            }
        } catch {}

        guard screenshotScanId == currentId else { return }
        screenshotScanState = .done
        saveCache()
    }

    func scanFiles() async {
        let currentId = UUID()
        fileScanId = currentId

        fileScanState = .scanning
        let engine = FileScanEngine()
        do {
            let files = try await engine.scan()
            guard fileScanId == currentId else { return }
            largeFiles    = files
            fileScanState = .done
            saveCache()
        } catch {
            guard fileScanId == currentId else { return }
            fileScanState = .failed(error.localizedDescription)
        }
    }

    func scanContacts() async {
        let currentId = UUID()
        contactScanId    = currentId
        contactScanState = .scanning
        contactMatches   = []

        let engine = ContactScanEngine()
        do {
            let matches = try await engine.scan()
            guard contactScanId == currentId else { return }
            contactMatches   = matches
            contactScanState = .done
        } catch {
            guard contactScanId == currentId else { return }
            contactScanState = .failed(error.localizedDescription)
        }
    }

    func scanBlur() async {
        let currentId = UUID()
        blurScanId = currentId

        blurScanState = .scanning
        blurProgress  = (0, 0)
        let addedAfter: Date? = lastScanDate.flatMap { blurPhotos.isEmpty ? nil : $0 }
        if addedAfter == nil { blurPhotos = [] }

        let engine = BlurScanEngine()
        do {
            for try await event in engine.scan(addedAfter: addedAfter) {
                guard blurScanId == currentId else { return }
                switch event {
                case .progress(let c, let t):
                    blurProgress = (c, t)
                case .blurryPhotosFound(let photos):
                    if addedAfter != nil {
                        let existingIDs = Set(blurPhotos.map(\.localIdentifier))
                        blurPhotos += photos.filter { !existingIDs.contains($0.localIdentifier) }
                    } else {
                        blurPhotos = photos
                    }
                    if blurProgress.total > 0 {
                        blurProgress = (blurProgress.total, blurProgress.total)
                    }
                }
            }
        } catch {}

        guard blurScanId == currentId else { return }
        blurScanState = .done
        saveCache()

        // Kick off Smart Picks computation if we have material from either scan
        if !blurPhotos.isEmpty || !photoGroups.isEmpty {
            Task { await self.computeSmartPicks() }
        }
    }

    func scanLargePhotos() async {
        let currentId = UUID()
        largePhotoScanId    = currentId
        largePhotoScanState = .scanning
        largePhotoProgress  = (0, 0)
        let addedAfter: Date? = lastScanDate.flatMap { largePhotos.isEmpty ? nil : $0 }
        if addedAfter == nil { largePhotos = [] }

        let engine = LargePhotoScanEngine()
        do {
            for try await event in engine.scan(addedAfter: addedAfter) {
                guard largePhotoScanId == currentId else { return }
                switch event {
                case .progress(let c, let t):
                    largePhotoProgress = (c, t)
                case .photosFound(let newPhotos):
                    if addedAfter != nil {
                        let existingIDs = Set(largePhotos.map { $0.asset.localIdentifier })
                        let merged = largePhotos + newPhotos.filter { !existingIDs.contains($0.asset.localIdentifier) }
                        largePhotos = merged.sorted { $0.byteSize > $1.byteSize }
                    } else {
                        largePhotos = newPhotos
                    }
                    if largePhotoProgress.total > 0 {
                        largePhotoProgress = (largePhotoProgress.total, largePhotoProgress.total)
                    }
                }
            }
        } catch {}

        guard largePhotoScanId == currentId else { return }
        largePhotoScanState = .done
        saveCache()
    }

    func scanSemantic() async {
        let currentId = UUID()
        semanticScanId    = currentId
        semanticScanState = .scanning
        semanticGroups    = []

        let engine = SemanticScanEngine()
        do {
            for try await event in engine.scan() {
                guard semanticScanId == currentId else { return }
                switch event {
                case .progress:
                    break   // progress not exposed to UI in this phase
                case .resultsFound(let groups):
                    semanticGroups = groups
                }
            }
        } catch {
            guard semanticScanId == currentId else { return }
            semanticScanState = .failed(error.localizedDescription)
            return
        }

        guard semanticScanId == currentId else { return }
        semanticScanState = .done
    }

    func scanEventRolls() async {
        let currentId = UUID()
        eventRollScanId    = currentId
        eventRollScanState = .scanning
        eventRolls         = []

        let engine = EventRollScanEngine()
        do {
            for try await event in engine.scan() {
                guard eventRollScanId == currentId else { return }
                switch event {
                case .progress:
                    break   // progress not surfaced to UI (geocoding serialises anyway)
                case .rollsFound(let rolls):
                    eventRolls = rolls
                }
            }
        } catch {
            guard eventRollScanId == currentId else { return }
            eventRollScanState = .failed(error.localizedDescription)
            return
        }

        guard eventRollScanId == currentId else { return }
        eventRollScanState = .done
    }

    // MARK: - Smart Picks

    func computeSmartPicks() async {
        smartPicksScanState = .scanning
        smartPicks = []
        smartPicksReasons = [:]

        // ── Phase 1: quality-score candidates ───────────────────────────────
        // Gather candidates: blur photos + non-best assets from photo groups
        var candidates: [PHAsset] = []
        candidates.append(contentsOf: blurPhotos)
        for group in photoGroups {
            candidates.append(contentsOf: group.assets.dropFirst())
        }

        // Deduplicate by localIdentifier
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.localIdentifier).inserted }

        // Score all candidates concurrently (max 4 in-flight)
        var scored: [(asset: PHAsset, score: Float)] = []
        if !candidates.isEmpty {
            await withTaskGroup(of: (PHAsset, Float).self) { group in
                var nextIndex = 0
                var inFlight = 0
                while inFlight < 4, nextIndex < candidates.count {
                    let a = candidates[nextIndex]; nextIndex += 1
                    group.addTask {
                        let score = await PhotoQualityAnalyzer.shared.qualityScore(for: a)
                        return (a, score)
                    }
                    inFlight += 1
                }
                for await (asset, score) in group {
                    scored.append((asset, score))
                    if nextIndex < candidates.count {
                        let a = candidates[nextIndex]; nextIndex += 1
                        group.addTask {
                            let score = await PhotoQualityAnalyzer.shared.qualityScore(for: a)
                            return (a, score)
                        }
                    }
                }
            }
        }

        // Sort ascending (lowest quality = most likely to delete)
        scored.sort { $0.score < $1.score }
        let qualityPicks = Array(scored.prefix(200).map(\.asset))

        // ── Phase 2: wasted-shot detection ──────────────────────────────────
        // Read user affinity — categories deleted ≥5 times get 2× scan cap.
        let affinityCounts = await WastedReasonAffinityStore.shared.allCounts()
        let expandedScan = affinityCounts.values.contains { $0 >= 5 }
        let effectiveCap = expandedScan ? 1000 : 500

        let alreadyFlagged = Set(qualityPicks.map(\.localIdentifier)).union(seen)
        let wastedAssets = await detectWastedShots(excluding: alreadyFlagged, cap: effectiveCap)

        // Sort wasted shots by deletion affinity (most-deleted category first).
        let sortedWasted = wastedAssets.sorted { a, b in
            (affinityCounts[a.1] ?? 0) > (affinityCounts[b.1] ?? 0)
        }

        // Merge order:
        //   1. High-affinity wasted shots (≥3 deletes) — user clearly wants these gone
        //   2. Quality-score picks
        //   3. Remaining wasted shots
        var finalList: [PHAsset] = []
        var reasons: [String: WastedReason] = [:]

        for (asset, reason) in sortedWasted where (affinityCounts[reason] ?? 0) >= 3 {
            let id = asset.localIdentifier
            guard !alreadyFlagged.contains(id) else { continue }
            finalList.append(asset)
            reasons[id] = reason
        }

        let highAffinityIDs = Set(finalList.map(\.localIdentifier))
        for asset in qualityPicks where !highAffinityIDs.contains(asset.localIdentifier) {
            finalList.append(asset)
        }

        for (asset, reason) in sortedWasted {
            let id = asset.localIdentifier
            guard !alreadyFlagged.contains(id), reasons[id] == nil,
                  !highAffinityIDs.contains(id) else { continue }
            finalList.append(asset)
            reasons[id] = reason
        }

        smartPicks = finalList
        smartPicksReasons = reasons
        smartPicksScanState = .done
    }

    // MARK: - Wasted-shot detection helpers

    /// Returns up to `cap` photos (from the whole library, excluding `excluding`) that are
    /// flagged as dark shots, QR-code photos, or screen photos.
    private func detectWastedShots(
        excluding: Set<String>,
        cap: Int
    ) async -> [(PHAsset, WastedReason)] {
        // Fetch recent photos, newest first, skip Live Photo burst sub-resources etc.
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: opts)

        // Build a candidate list (skip already-flagged assets)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, stop in
            guard !excluding.contains(asset.localIdentifier) else { return }
            assets.append(asset)
            if assets.count >= cap { stop.pointee = true }
        }

        guard !assets.isEmpty else { return [] }

        // Run detection concurrently — cap at 4 in-flight to limit memory
        var detections: [(PHAsset, WastedReason)] = []
        await withTaskGroup(of: (PHAsset, WastedReason)?.self) { group in
            var nextIndex = 0
            var inFlight = 0

            while inFlight < 4, nextIndex < assets.count {
                let a = assets[nextIndex]; nextIndex += 1
                group.addTask { await Self.classifyWastedShot(a) }
                inFlight += 1
            }

            for await result in group {
                inFlight -= 1
                if let (asset, reason) = result {
                    detections.append((asset, reason))
                }
                if nextIndex < assets.count {
                    let a = assets[nextIndex]; nextIndex += 1
                    group.addTask { await Self.classifyWastedShot(a) }
                    inFlight += 1
                }
            }
        }

        return detections
    }

    /// Classifies a single asset as a wasted shot, returning (asset, reason) or nil if not flagged.
    private static func classifyWastedShot(_ asset: PHAsset) async -> (PHAsset, WastedReason)? {
        // Request a small thumbnail for fast analysis
        let image: UIImage? = await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 512, height: 512),
                contentMode: .aspectFit,
                options: opts
            ) { img, info in
                guard !resumed else { return }
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                resumed = true
                continuation.resume(returning: img)
            }
        }

        guard let image, let cgImage = image.cgImage else { return nil }

        // ── Compute mean luminance once (reused across checks) ────────────────
        var luminance: Float = 0.5  // conservative default
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let extentVector = CIVector(x: ciImage.extent.origin.x,
                                    y: ciImage.extent.origin.y,
                                    z: ciImage.extent.size.width,
                                    w: ciImage.extent.size.height)
        if let areaAvgFilter = CIFilter(name: "CIAreaAverage",
                                         parameters: [kCIInputImageKey: ciImage,
                                                      kCIInputExtentKey: extentVector]),
           let outputImage = areaAvgFilter.outputImage {
            var bitmap = [UInt8](repeating: 0, count: 4)
            context.render(outputImage,
                           toBitmap: &bitmap,
                           rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            let r = Float(bitmap[0]) / 255
            let g = Float(bitmap[1]) / 255
            let b = Float(bitmap[2]) / 255
            luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        // ── 1. Dark shot: mean luminance < 8% ────────────────────────────────
        if luminance < 0.08 { return (asset, .darkShot) }

        // ── 2. QR / Barcode ──────────────────────────────────────────────────
        let barcodeRequest = VNDetectBarcodesRequest()
        let barcodeHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? barcodeHandler.perform([barcodeRequest])
        if let barcodeResults = barcodeRequest.results, !barcodeResults.isEmpty {
            return (asset, .qrCode)
        }

        // ── 3. Screen photo ──────────────────────────────────────────────────
        let classifyRequest = VNClassifyImageRequest()
        let classifyHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? classifyHandler.perform([classifyRequest])
        if let observations = classifyRequest.results {
            let screenIdentifiers = ["television", "monitor", "screen",
                                     "laptop", "computer", "cellular_telephone",
                                     "desktop_computer", "notebook"]
            for obs in observations where obs.confidence > 0.35 {
                if screenIdentifiers.contains(where: { obs.identifier.contains($0) }) {
                    return (asset, .screenPhoto)
                }
            }
        }

        // ── 4 & 5. Text-based checks (run recognition once, use for both) ────
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([textRequest])
        let textObservations = textRequest.results ?? []
        let recognizedStrings = textObservations.compactMap { $0.topCandidates(1).first?.string }

        // ── 4. Whiteboard / note capture: light bg + dense text + no face ─────
        if luminance > 0.55, textObservations.count >= 6 {
            let faceRequest = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([faceRequest])
            if (faceRequest.results?.count ?? 0) == 0 {
                return (asset, .whiteboard)
            }
        }

        // ── 5. Meme / forwarded: watermark strings OR very dense text overlay ──
        if !recognizedStrings.isEmpty {
            let joined = recognizedStrings.joined(separator: " ").lowercased()
            let watermarkKeywords = ["tiktok", "repost", "forwarded", "via @",
                                     "share this", "follow me", "dm for credit"]
            let hasWatermark = watermarkKeywords.contains { joined.contains($0) }
            if hasWatermark || recognizedStrings.count >= 14 {
                return (asset, .memeForwarded)
            }
        }

        return nil
    }

    // MARK: - Video Duplicates

    func scanVideoDuplicates() async {
        let currentId = UUID()
        videoDuplicateScanId    = currentId
        videoDuplicateScanState = .scanning
        videoGroups             = []

        let engine = VideoDuplicateEngine()
        do {
            for try await event in engine.scan() {
                guard videoDuplicateScanId == currentId else { return }
                switch event {
                case .progress:
                    break   // progress not surfaced to UI for video scanning
                case .groupsFound(let groups):
                    videoGroups = groups
                }
            }
        } catch {
            guard videoDuplicateScanId == currentId else { return }
            videoDuplicateScanState = .failed(error.localizedDescription)
            return
        }

        guard videoDuplicateScanId == currentId else { return }
        videoDuplicateScanState = .done
    }

    // MARK: - Recently Deleted

    func scanRecentlyDeleted() async {
        recentlyDeletedScanState = .scanning
        recentlyDeletedPhotos    = []
        recentlyDeletedBytes     = 0

        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            recentlyDeletedScanState = .done
            return
        }
        let subtype = PHAssetCollectionSubtype(rawValue: 1000000201)!
        let albums  = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: subtype, options: nil)
        guard let album = albums.firstObject else {
            recentlyDeletedScanState = .done
            return
        }

        var assets: [PHAsset] = []
        PHAsset.fetchAssets(in: album, options: nil)
            .enumerateObjects { asset, _, _ in assets.append(asset) }

        var totalBytes: Int64 = 0
        for asset in assets {
            let resources = PHAssetResource.assetResources(for: asset)
            if let resource = resources.first,
               let size = resource.value(forKey: "fileSize") as? Int64, size > 0 {
                totalBytes += size
            }
        }

        recentlyDeletedPhotos = assets
        recentlyDeletedBytes  = totalBytes
        recentlyDeletedScanState = .done
    }

    func emptyRecentlyDeleted() async throws {
        let toDelete = recentlyDeletedPhotos
        guard !toDelete.isEmpty else { return }
        let nsArray = toDelete as NSArray
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(nsArray)
        }
        let count = toDelete.count
        addBytesFreed(recentlyDeletedBytes)
        addPhotosDeleted(count)
        recentlyDeletedPhotos    = []
        recentlyDeletedBytes     = 0
        recentlyDeletedScanState = .idle
    }

    // MARK: - Persistence

    private var cacheURL: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("photoduck_scan_v1.json")
    }

    /// Migrate cache from old Caches-directory location (one-time, silent).
    private func migrateOldCache() {
        let fm = FileManager.default
        let oldDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let oldURL = oldDir.appendingPathComponent("photoduck_scan_v1.json")
        guard fm.fileExists(atPath: oldURL.path) else { return }
        let newURL = cacheURL
        guard !fm.fileExists(atPath: newURL.path) else {
            try? fm.removeItem(at: oldURL)
            return
        }
        try? fm.moveItem(at: oldURL, to: newURL)
    }

    private func saveCache() {
        let cachedGroups = photoGroups.map { group in
            CachedPhotoGroup(
                id: group.id,
                localIdentifiers: group.assets.map(\.localIdentifier),
                similarity: group.similarity,
                reasonKey: group.reason.cacheKey
            )
        }
        let cachedFiles = largeFiles.compactMap { file -> CachedLargeFile? in
            switch file.source {
            case .photoLibrary(let asset):
                return CachedLargeFile(
                    id: file.id, sourceType: "photoLibrary",
                    localIdentifier: asset.localIdentifier, urlString: nil,
                    displayName: file.displayName, byteSize: file.byteSize,
                    creationDate: file.creationDate
                )
            case .filesystem(let url):
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return CachedLargeFile(
                    id: file.id, sourceType: "filesystem",
                    localIdentifier: nil, urlString: url.absoluteString,
                    displayName: file.displayName, byteSize: file.byteSize,
                    creationDate: file.creationDate
                )
            }
        }

        let now = Date()
        let cache = ScanResultsCache(
            version: 1, savedAt: now,
            photoGroups: cachedGroups,
            largeFiles: cachedFiles,
            blurPhotoIds: blurPhotos.map(\.localIdentifier),
            screenshotPhotoIds: screenshotAssets.map(\.localIdentifier),
            largePhotoIds: largePhotos.map(\.asset.localIdentifier),
            largePhotoSizes: largePhotos.map(\.byteSize)
        )
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomic)
            lastScanDate = now
        } catch {
            // Non-fatal: next scan will overwrite.
        }
    }

    /// Non-blocking version of loadCache — runs the disk I/O and PHAsset reconstruction
    /// on whatever thread calls it (intended: Task.detached), then hops to MainActor to publish.
    private func loadCacheOffMain() async {
        // Migrate old cache path first (one-time, fast).
        migrateOldCache()

        guard let data  = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(ScanResultsCache.self, from: data)
        else { return }

        let savedAt = cache.savedAt

        // ── Reconstruct all PHAssets off main thread ───────────────────────
        // Photo groups
        let allIds = cache.photoGroups.flatMap(\.localIdentifiers)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: allIds, options: nil)
        var assetMap: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in assetMap[asset.localIdentifier] = asset }

        let rebuiltGroups: [PhotoGroup] = cache.photoGroups.compactMap { cached in
            guard let reason = PhotoGroup.SimilarityReason(cacheKey: cached.reasonKey) else { return nil }
            let assets = cached.localIdentifiers.compactMap { assetMap[$0] }
            guard assets.count >= 2 else { return nil }
            return PhotoGroup(id: cached.id, assets: assets, similarity: cached.similarity, reason: reason)
        }

        // Large files
        let fileIds = cache.largeFiles.compactMap(\.localIdentifier)
        let fileFetch = PHAsset.fetchAssets(withLocalIdentifiers: fileIds, options: nil)
        var fileAssetMap: [String: PHAsset] = [:]
        fileFetch.enumerateObjects { asset, _, _ in fileAssetMap[asset.localIdentifier] = asset }

        let rebuiltFiles: [LargeFile] = cache.largeFiles.compactMap { cached in
            switch cached.sourceType {
            case "photoLibrary":
                guard let id = cached.localIdentifier, let asset = fileAssetMap[id] else { return nil }
                return LargeFile(id: cached.id, source: .photoLibrary(asset: asset),
                                 displayName: cached.displayName, byteSize: cached.byteSize,
                                 creationDate: cached.creationDate)
            case "filesystem":
                guard let urlString = cached.urlString, let url = URL(string: urlString),
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return LargeFile(id: cached.id, source: .filesystem(url: url),
                                 displayName: cached.displayName, byteSize: cached.byteSize,
                                 creationDate: cached.creationDate)
            default: return nil
            }
        }

        // Blur
        var rebuiltBlur: [PHAsset] = []
        if !cache.blurPhotoIds.isEmpty {
            let f = PHAsset.fetchAssets(withLocalIdentifiers: cache.blurPhotoIds, options: nil)
            f.enumerateObjects { a, _, _ in rebuiltBlur.append(a) }
        }

        // Screenshots
        var rebuiltShots: [PHAsset] = []
        if !cache.screenshotPhotoIds.isEmpty {
            let f = PHAsset.fetchAssets(withLocalIdentifiers: cache.screenshotPhotoIds, options: nil)
            f.enumerateObjects { a, _, _ in rebuiltShots.append(a) }
        }

        // Large photos
        let lpIds   = cache.largePhotoIds
        let lpSizes = cache.largePhotoSizes
        var rebuiltLargePhotos: [LargePhotoItem] = []
        if !lpIds.isEmpty && lpIds.count == lpSizes.count {
            let f = PHAsset.fetchAssets(withLocalIdentifiers: lpIds, options: nil)
            var lpMap: [String: PHAsset] = [:]
            f.enumerateObjects { a, _, _ in lpMap[a.localIdentifier] = a }
            rebuiltLargePhotos = zip(lpIds, lpSizes).compactMap { id, size in
                guard let asset = lpMap[id] else { return nil }
                return LargePhotoItem(id: UUID(), asset: asset, byteSize: size)
            }
        }

        // ── Publish on MainActor ───────────────────────────────────────────
        await MainActor.run {
            lastScanDate = savedAt
            photoGroups  = rebuiltGroups
            largeFiles   = rebuiltFiles
            blurPhotos   = rebuiltBlur
            screenshotAssets = rebuiltShots
            largePhotos  = rebuiltLargePhotos

            if !photoGroups.isEmpty      { photoScanState      = .done }
            if !largeFiles.isEmpty       { fileScanState       = .done }
            if !blurPhotos.isEmpty       { blurScanState       = .done }
            if !screenshotAssets.isEmpty { screenshotScanState = .done }
            if !largePhotos.isEmpty      { largePhotoScanState = .done }
        }
    }

    private func loadCache() {
        migrateOldCache()
        guard let data  = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(ScanResultsCache.self, from: data)
        else { return }

        lastScanDate = cache.savedAt

        // Photo groups
        let allIds = cache.photoGroups.flatMap(\.localIdentifiers)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: allIds, options: nil)
        var assetMap: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in assetMap[asset.localIdentifier] = asset }

        photoGroups = cache.photoGroups.compactMap { cached -> PhotoGroup? in
            guard let reason = PhotoGroup.SimilarityReason(cacheKey: cached.reasonKey) else { return nil }
            let assets = cached.localIdentifiers.compactMap { assetMap[$0] }
            guard assets.count >= 2 else { return nil }
            return PhotoGroup(id: cached.id, assets: assets, similarity: cached.similarity, reason: reason)
        }

        // Large files
        let fileIds = cache.largeFiles.compactMap(\.localIdentifier)
        let fileFetch = PHAsset.fetchAssets(withLocalIdentifiers: fileIds, options: nil)
        var fileAssetMap: [String: PHAsset] = [:]
        fileFetch.enumerateObjects { asset, _, _ in fileAssetMap[asset.localIdentifier] = asset }

        largeFiles = cache.largeFiles.compactMap { cached -> LargeFile? in
            switch cached.sourceType {
            case "photoLibrary":
                guard let id = cached.localIdentifier, let asset = fileAssetMap[id] else { return nil }
                return LargeFile(id: cached.id, source: .photoLibrary(asset: asset),
                                 displayName: cached.displayName, byteSize: cached.byteSize,
                                 creationDate: cached.creationDate)
            case "filesystem":
                guard let urlString = cached.urlString, let url = URL(string: urlString),
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return LargeFile(id: cached.id, source: .filesystem(url: url),
                                 displayName: cached.displayName, byteSize: cached.byteSize,
                                 creationDate: cached.creationDate)
            default:
                return nil
            }
        }

        // Blur photos
        if !cache.blurPhotoIds.isEmpty {
            let blurFetch = PHAsset.fetchAssets(withLocalIdentifiers: cache.blurPhotoIds, options: nil)
            var blurAssets: [PHAsset] = []
            blurFetch.enumerateObjects { asset, _, _ in blurAssets.append(asset) }
            blurPhotos = blurAssets
        }

        // Screenshots
        if !cache.screenshotPhotoIds.isEmpty {
            let shotFetch = PHAsset.fetchAssets(withLocalIdentifiers: cache.screenshotPhotoIds, options: nil)
            var shotAssets: [PHAsset] = []
            shotFetch.enumerateObjects { asset, _, _ in shotAssets.append(asset) }
            screenshotAssets = shotAssets
        }

        // Large photos
        let lpIds   = cache.largePhotoIds
        let lpSizes = cache.largePhotoSizes
        if !lpIds.isEmpty && lpIds.count == lpSizes.count {
            let lpFetch = PHAsset.fetchAssets(withLocalIdentifiers: lpIds, options: nil)
            var lpMap: [String: PHAsset] = [:]
            lpFetch.enumerateObjects { asset, _, _ in lpMap[asset.localIdentifier] = asset }
            largePhotos = zip(lpIds, lpSizes).compactMap { id, size -> LargePhotoItem? in
                guard let asset = lpMap[id] else { return nil }
                return LargePhotoItem(id: UUID(), asset: asset, byteSize: size)
            }
        }

        if !photoGroups.isEmpty      { photoScanState      = .done }
        if !largeFiles.isEmpty       { fileScanState       = .done }
        if !blurPhotos.isEmpty       { blurScanState       = .done }
        if !screenshotAssets.isEmpty { screenshotScanState = .done }
        if !largePhotos.isEmpty      { largePhotoScanState = .done }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
        photoGroups      = []
        contactMatches   = []
        largeFiles       = []
        blurPhotos       = []
        screenshotAssets = []
        largePhotos      = []
        semanticGroups   = []
        eventRolls       = []
        videoGroups      = []
        photoScanState          = .idle
        fileScanState           = .idle
        blurScanState           = .idle
        screenshotScanState     = .idle
        largePhotoScanState     = .idle
        contactScanState        = .idle
        semanticScanState       = .idle
        eventRollScanState      = .idle
        videoDuplicateScanState = .idle
        smartPicks              = []
        smartPicksReasons       = [:]
        smartPicksScanState     = .idle
        lastScanDate            = nil
    }

    /// Wipes all cached results and runs every engine from scratch.
    /// Called only from Settings — the regular scan button does incremental.
    func fullRescan() async {
        clearCache()
        await refreshTotalLibraryCount()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.scanPhotos() }
            group.addTask { await self.scanFiles() }
            group.addTask { await self.scanBlur() }
            group.addTask { await self.scanScreenshots() }
            group.addTask { await self.scanLargePhotos() }
            group.addTask { await self.scanContacts() }
            group.addTask { await self.scanSemantic() }
            group.addTask { await self.scanEventRolls() }
        }
    }

    // MARK: - Cancel scan

    private(set) var activeScanTask: Task<Void, Never>?

    func registerScanTask(_ task: Task<Void, Never>) {
        activeScanTask = task
    }

    func cancelScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        photoScanState      = .idle
        fileScanState       = .idle
        blurScanState       = .idle
        screenshotScanState     = .idle
        largePhotoScanState     = .idle
        contactScanState        = .idle
        semanticScanState       = .idle
        eventRollScanState      = .idle
        videoDuplicateScanState = .idle
        smartPicksScanState     = .idle
        scanStartTime           = nil
    }
}
