import AVFoundation
import Foundation
import Photos

enum AssetMediaKind: String, Codable, Sendable {
    case image
    case video
    case other

    init(_ mediaType: PHAssetMediaType) {
        switch mediaType {
        case .image:
            self = .image
        case .video:
            self = .video
        default:
            self = .other
        }
    }
}

enum AssetResourceKind: Sendable, Equatable {
    case photo
    case video
    case audio
    case alternatePhoto
    case fullSizePhoto
    case fullSizeVideo
    case adjustmentData
    case adjustmentBasePhoto
    case pairedVideo
    case fullSizePairedVideo
    case adjustmentBasePairedVideo
    case adjustmentBaseVideo
    case other

    init(_ type: PHAssetResourceType) {
        switch type {
        case .photo:
            self = .photo
        case .video:
            self = .video
        case .audio:
            self = .audio
        case .alternatePhoto:
            self = .alternatePhoto
        case .fullSizePhoto:
            self = .fullSizePhoto
        case .fullSizeVideo:
            self = .fullSizeVideo
        case .adjustmentData:
            self = .adjustmentData
        case .adjustmentBasePhoto:
            self = .adjustmentBasePhoto
        case .pairedVideo:
            self = .pairedVideo
        case .fullSizePairedVideo:
            self = .fullSizePairedVideo
        case .adjustmentBasePairedVideo:
            self = .adjustmentBasePairedVideo
        case .adjustmentBaseVideo:
            self = .adjustmentBaseVideo
        case .photoProxy:
            self = .other
        @unknown default:
            self = .other
        }
    }
}

/// Public-API-only metadata used by the representative-resource policy.
///
/// `PHAssetResource` intentionally has no public file-size property. Production
/// candidates therefore start with `byteCount == nil`; tests and other public
/// metadata providers can supply a known byte count without changing selection.
struct AssetResourceSizeCandidate: Sendable, Equatable {
    let kind: AssetResourceKind
    let originalFilename: String
    let byteCount: Int64?

    init(kind: AssetResourceKind, originalFilename: String, byteCount: Int64? = nil) {
        self.kind = kind
        self.originalFilename = originalFilename
        self.byteCount = byteCount
    }

    init(resource: PHAssetResource) {
        kind = AssetResourceKind(resource.type)
        originalFilename = resource.originalFilename
        byteCount = nil
    }
}

struct AssetByteSizeResolution: Sendable, Equatable {
    let bytes: Int64
    let isEstimated: Bool
}

enum AssetResourceSizePolicy {
    /// Select one current representative resource. Related resources such as
    /// adjustment data and a Live Photo's paired video are never summed.
    static func representative(
        from candidates: [AssetResourceSizeCandidate],
        mediaKind: AssetMediaKind
    ) -> AssetResourceSizeCandidate? {
        candidates.enumerated()
            .compactMap { index, candidate -> (rank: Int, index: Int, candidate: AssetResourceSizeCandidate)? in
                guard let rank = rank(for: candidate.kind, mediaKind: mediaKind) else { return nil }
                return (rank, index, candidate)
            }
            .min {
                if $0.rank == $1.rank {
                    return $0.index < $1.index
                }
                return $0.rank < $1.rank
            }?
            .candidate
    }

    static func displayFilename(
        from candidates: [AssetResourceSizeCandidate],
        mediaKind: AssetMediaKind
    ) -> String {
        let selectedName = representative(from: candidates, mediaKind: mediaKind)?
            .originalFilename
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedName, !selectedName.isEmpty {
            return selectedName
        }

        if let availableName = candidates.lazy
            .map(\.originalFilename)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return availableName
        }

        switch mediaKind {
        case .video:
            return "Video.mov"
        case .image:
            return "Photo.heic"
        case .other:
            return "Media"
        }
    }

    /// Resolves one byte count for the selected representative resource.
    ///
    /// A URL-backed current-version measurement is preferred. A known size on
    /// the selected candidate is next. The final fallback is media-aware and is
    /// explicitly marked as an estimate.
    static func resolveByteCount(
        candidates: [AssetResourceSizeCandidate],
        mediaKind: AssetMediaKind,
        measuredCurrentVersionBytes: Int64?,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval
    ) -> AssetByteSizeResolution {
        if let measuredCurrentVersionBytes, measuredCurrentVersionBytes > 0 {
            return AssetByteSizeResolution(bytes: measuredCurrentVersionBytes, isEstimated: false)
        }

        if let knownBytes = representative(from: candidates, mediaKind: mediaKind)?.byteCount,
           knownBytes > 0 {
            return AssetByteSizeResolution(bytes: knownBytes, isEstimated: false)
        }

        return AssetByteSizeResolution(
            bytes: estimatedByteCount(
                mediaKind: mediaKind,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                duration: duration
            ),
            isEstimated: true
        )
    }

    static func estimatedByteCount(
        mediaKind: AssetMediaKind,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval
    ) -> Int64 {
        let width = max(pixelWidth, 0)
        let height = max(pixelHeight, 0)
        let pixelCount = Int64(width) * Int64(height)

        switch mediaKind {
        case .image:
            // Roughly 0.33 bytes/pixel is conservative for modern HEIC/JPEG.
            return max(pixelCount / 3, 0)
        case .video:
            guard duration > 0 else { return 0 }
            let estimatedBitsPerSecond: Double
            switch pixelCount {
            case 8_000_000...:
                estimatedBitsPerSecond = 35_000_000
            case 2_000_000...:
                estimatedBitsPerSecond = 12_000_000
            case 900_000...:
                estimatedBitsPerSecond = 6_000_000
            default:
                estimatedBitsPerSecond = 3_000_000
            }
            return max(Int64((duration * estimatedBitsPerSecond) / 8), 0)
        case .other:
            return 0
        }
    }

    private static func rank(for kind: AssetResourceKind, mediaKind: AssetMediaKind) -> Int? {
        switch mediaKind {
        case .video:
            switch kind {
            case .fullSizeVideo:
                return 0
            case .video:
                return 1
            case .adjustmentBaseVideo:
                return 2
            case .fullSizePairedVideo:
                return 3
            case .pairedVideo:
                return 4
            case .adjustmentBasePairedVideo:
                return 5
            default:
                return nil
            }
        case .image:
            switch kind {
            case .fullSizePhoto:
                return 0
            case .photo:
                return 1
            case .alternatePhoto:
                return 2
            case .adjustmentBasePhoto:
                return 3
            default:
                return nil
            }
        case .other:
            switch kind {
            case .adjustmentData, .audio:
                return nil
            default:
                return 0
            }
        }
    }
}

struct PHAssetRepresentativeFile: Sendable, Equatable {
    let displayName: String
    let byteSize: Int64
    let byteSizeIsEstimated: Bool
    let wasCached: Bool
}

struct AssetFileSizeCacheKey: Codable, Hashable, Sendable {
    let localIdentifier: String
    let modificationDate: Date?
}

enum AssetFileSizeProvenance: String, Codable, Sendable {
    case measuredCurrentVersion
    case estimated
}

struct AssetFileSizeRecord: Codable, Equatable, Sendable {
    let bytes: Int64
    let provenance: AssetFileSizeProvenance
    let savedAt: Date
    /// Which media type produced this record. Optional so stores written
    /// before this field decode unchanged; a nil value is treated as
    /// out-of-scope by `retain` and therefore preserved.
    var mediaKind: AssetMediaKind?

    var isEstimated: Bool {
        provenance == .estimated
    }
}

private final class AssetFileSizeCache: @unchecked Sendable {
    static let shared = AssetFileSizeCache()
    private struct Entry {
        let value: AssetFileSizeRecord
        var accessOrdinal: UInt64
    }

    private let lock = NSLock()
    private let maximumEntryCount = 2_048
    private var values: [AssetFileSizeCacheKey: Entry] = [:]
    private var accessOrdinal: UInt64 = 0

    func value(for key: AssetFileSizeCacheKey) -> AssetFileSizeRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = values[key] else { return nil }
        accessOrdinal &+= 1
        entry.accessOrdinal = accessOrdinal
        values[key] = entry
        return entry.value
    }

    func store(_ value: AssetFileSizeRecord, for key: AssetFileSizeCacheKey) {
        guard value.bytes > 0 else { return }
        lock.lock()
        accessOrdinal &+= 1
        values[key] = Entry(value: value, accessOrdinal: accessOrdinal)
        if values.count > maximumEntryCount,
           let leastRecentlyUsedKey = values.min(by: {
               $0.value.accessOrdinal < $1.value.accessOrdinal
           })?.key {
            values.removeValue(forKey: leastRecentlyUsedKey)
        }
        lock.unlock()
    }
}

actor AssetFileSizeRepository {
    static let shared = AssetFileSizeRepository()
    static let schemaVersion = 1
    private static let maximumFileBytes = 8 * 1_024 * 1_024

    private struct PersistentEntry: Codable, Sendable {
        let key: AssetFileSizeCacheKey
        let record: AssetFileSizeRecord
        let accessOrdinal: UInt64
    }

    private struct Snapshot: Codable, Sendable {
        let schemaVersion: Int
        let entries: [PersistentEntry]
    }

    private struct StoredEntry: Sendable {
        let record: AssetFileSizeRecord
        var accessOrdinal: UInt64
    }

    private let fileURL: URL
    private let maximumEntryCount: Int
    private var entries: [AssetFileSizeCacheKey: StoredEntry] = [:]
    private var accessOrdinal: UInt64 = 0
    private var isLoaded = false
    private var loadTask: Task<Snapshot?, Never>?
    private var writeTask: Task<Void, Never>?
    private var needsWrite = false

    init(fileURL: URL? = nil, maximumEntryCount: Int = 10_000) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = baseURL
                .appendingPathComponent("PhotoDuck", isDirectory: true)
                .appendingPathComponent("asset-file-sizes-v1.json")
        }
        self.maximumEntryCount = max(maximumEntryCount, 1)
    }

    func value(for key: AssetFileSizeCacheKey) async -> AssetFileSizeRecord? {
        await loadIfNeeded()
        guard var entry = entries[key] else { return nil }
        accessOrdinal &+= 1
        entry.accessOrdinal = accessOrdinal
        entries[key] = entry
        AssetFileSizeCache.shared.store(entry.record, for: key)
        return entry.record
    }

    func store(
        _ record: AssetFileSizeRecord,
        for key: AssetFileSizeCacheKey
    ) async {
        guard record.bytes > 0 else { return }
        await loadIfNeeded()
        accessOrdinal &+= 1
        entries[key] = StoredEntry(
            record: record,
            accessOrdinal: accessOrdinal
        )
        evictIfNeeded()
        AssetFileSizeCache.shared.store(record, for: key)
        scheduleWrite()
    }

    /// Loads durable values into the bounded synchronous front cache used by
    /// model aggregation and deletion summaries.
    func warmMemoryCache() async {
        await loadIfNeeded()
        for (key, entry) in entries {
            AssetFileSizeCache.shared.store(entry.record, for: key)
        }
    }

    /// Drops records outside `localIdentifiers`, but only within the media
    /// types the caller actually enumerated. The video scan passes video IDs
    /// only, so an unscoped filter evicted every photo size measured by the
    /// export path — after which those photos silently fell back to estimates
    /// in deletion totals and reclaimable-space figures.
    func retain(
        localIdentifiers: Set<String>,
        limitedTo mediaKinds: Set<AssetMediaKind>? = nil
    ) async {
        await loadIfNeeded()
        let previousCount = entries.count
        entries = entries.filter { element in
            if let mediaKinds {
                guard let recordKind = element.value.record.mediaKind else {
                    // Unknown provenance — never evict on someone else's scan.
                    return true
                }
                guard mediaKinds.contains(recordKind) else {
                    // Out of scope for this caller — keep it.
                    return true
                }
            }
            return localIdentifiers.contains(element.key.localIdentifier)
        }
        if entries.count != previousCount {
            scheduleWrite()
        }
    }

    func flush() async {
        await loadIfNeeded()
        needsWrite = true
        if writeTask == nil {
            beginWrite()
        }
        while let task = writeTask {
            await task.value
        }
    }

    #if DEBUG
    func debugEntryCount() async -> Int {
        await loadIfNeeded()
        return entries.count
    }
    #endif

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        let task: Task<Snapshot?, Never>
        if let loadTask {
            task = loadTask
        } else {
            let fileURL = fileURL
            task = Task.detached(priority: .utility) {
                guard let attributes = try? FileManager.default.attributesOfItem(
                    atPath: fileURL.path
                ),
                let fileBytes = attributes[.size] as? NSNumber,
                fileBytes.intValue <= Self.maximumFileBytes,
                let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
                let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                snapshot.schemaVersion == Self.schemaVersion else {
                    return nil
                }
                return snapshot
            }
            loadTask = task
        }

        let snapshot = await task.value
        guard !isLoaded else { return }
        if let snapshot {
            entries.reserveCapacity(min(snapshot.entries.count, maximumEntryCount))
            for item in snapshot.entries
                .sorted(by: { $0.accessOrdinal > $1.accessOrdinal })
                .prefix(maximumEntryCount) {
                entries[item.key] = StoredEntry(
                    record: item.record,
                    accessOrdinal: item.accessOrdinal
                )
                accessOrdinal = max(accessOrdinal, item.accessOrdinal)
            }
        }
        isLoaded = true
        loadTask = nil
    }

    private func evictIfNeeded() {
        while entries.count > maximumEntryCount,
              let leastRecentlyUsed = entries.min(by: {
                  $0.value.accessOrdinal < $1.value.accessOrdinal
              }) {
            entries.removeValue(forKey: leastRecentlyUsed.key)
        }
    }

    private func scheduleWrite() {
        needsWrite = true
        guard writeTask == nil else { return }
        beginWrite()
    }

    private func beginWrite() {
        guard needsWrite else { return }
        needsWrite = false
        let snapshot = Snapshot(
            schemaVersion: Self.schemaVersion,
            entries: entries.map {
                PersistentEntry(
                    key: $0.key,
                    record: $0.value.record,
                    accessOrdinal: $0.value.accessOrdinal
                )
            }
        )
        let fileURL = fileURL
        writeTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                guard data.count <= Self.maximumFileBytes else {
                    await self?.writeDidFinish()
                    return
                }
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                // Size metadata is an optimization. A future measurement can
                // recreate the cache if persistence is unavailable.
            }
            await self?.writeDidFinish()
        }
    }

    private func writeDidFinish() {
        writeTask = nil
        if needsWrite {
            beginWrite()
        }
    }
}

private final class VideoFileSizeRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64?, Never>?
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Int64?, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setRequestID(_ requestID: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()
        if shouldCancel {
            manager.cancelImageRequest(requestID)
        }
    }

    func resolve(_ bytes: Int64?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: bytes)
    }

    func cancel(using manager: PHImageManager) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
        }
        continuation?.resume(returning: nil)
    }
}

extension PHAsset {
    /// Returns representative metadata without private KVC or summing variants.
    func representativeFile(allowNetworkAccess: Bool = false) async -> PHAssetRepresentativeFile {
        let mediaKind = AssetMediaKind(mediaType)
        let candidates = PHAssetResource.assetResources(for: self)
            .map(AssetResourceSizeCandidate.init(resource:))
        let cacheKey = fileSizeCacheKey
        if let cached = await AssetFileSizeRepository.shared.value(for: cacheKey) {
            return PHAssetRepresentativeFile(
                displayName: AssetResourceSizePolicy.displayFilename(
                    from: candidates,
                    mediaKind: mediaKind
                ),
                byteSize: cached.bytes,
                byteSizeIsEstimated: cached.isEstimated,
                wasCached: true
            )
        }
        let measuredBytes: Int64?
        if mediaKind == .video {
            measuredBytes = await currentVideoURLByteSize(allowNetworkAccess: allowNetworkAccess)
        } else {
            measuredBytes = nil
        }
        let resolution = AssetResourceSizePolicy.resolveByteCount(
            candidates: candidates,
            mediaKind: mediaKind,
            measuredCurrentVersionBytes: measuredBytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration
        )
        let record = AssetFileSizeRecord(
            bytes: resolution.bytes,
            provenance: resolution.isEstimated ? .estimated : .measuredCurrentVersion,
            savedAt: Date(),
            mediaKind: mediaKind
        )
        await AssetFileSizeRepository.shared.store(record, for: cacheKey)

        return PHAssetRepresentativeFile(
            displayName: AssetResourceSizePolicy.displayFilename(
                from: candidates,
                mediaKind: mediaKind
            ),
            byteSize: resolution.bytes,
            byteSizeIsEstimated: resolution.isEstimated,
            wasCached: false
        )
    }

    /// Returns the best cached or media-aware file-size estimate for this asset.
    ///
    /// FileScanEngine populates the cache with the public URL-backed current
    /// version when Photos exposes one. Other callers use the same fallback
    /// policy without synchronous PHAssetResource metadata work.
    var estimatedFileSize: Int64 {
        if let cached = AssetFileSizeCache.shared.value(for: fileSizeCacheKey) {
            return cached.bytes
        }
        return AssetResourceSizePolicy.estimatedByteCount(
            mediaKind: AssetMediaKind(mediaType),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration
        )
    }

    private var fileSizeCacheKey: AssetFileSizeCacheKey {
        AssetFileSizeCacheKey(
            localIdentifier: localIdentifier,
            modificationDate: modificationDate
        )
    }

    private func currentVideoURLByteSize(allowNetworkAccess: Bool) async -> Int64? {
        let manager = PHImageManager.default()
        let state = VideoFileSizeRequestState()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)

                let options = PHVideoRequestOptions()
                options.version = .current
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = allowNetworkAccess

                let requestID = manager.requestAVAsset(forVideo: self, options: options) { asset, _, _ in
                    guard let urlAsset = asset as? AVURLAsset,
                          let values = try? urlAsset.url.resourceValues(forKeys: [.fileSizeKey]),
                          let fileSize = values.fileSize,
                          fileSize > 0 else {
                        state.resolve(nil)
                        return
                    }
                    state.resolve(Int64(fileSize))
                }
                state.setRequestID(requestID, manager: manager)

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                    state.cancel(using: manager)
                }
            }
        } onCancel: {
            state.cancel(using: manager)
        }
    }
}
