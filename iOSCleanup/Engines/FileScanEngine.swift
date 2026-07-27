import Foundation
@preconcurrency import Photos

enum FileScanError: Error, Equatable, LocalizedError {
    case permissionDenied(PHAuthorizationStatus)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(.restricted):
            return "Photo access is restricted on this device."
        case .permissionDenied:
            return "Photo access is required to scan large videos. You can allow access in Settings."
        }
    }
}

struct FileScanAuthorizationProvider: Sendable {
    let currentStatus: @Sendable () -> PHAuthorizationStatus
    let requestReadWrite: @Sendable () async -> PHAuthorizationStatus

    static let live = FileScanAuthorizationProvider(
        currentStatus: {
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        },
        requestReadWrite: {
            await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
    )
}

protocol FileScanAssetProviding: Sendable {
    func fetchVideoAssets() async -> [PHAsset]
}

struct SystemFileScanAssetProvider: FileScanAssetProviding {
    func fetchVideoAssets() async -> [PHAsset] {
        let result = PHAsset.fetchAssets(with: .video, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }
}

struct FileScanProgress: Equatable, Sendable {
    static let idle = FileScanProgress(
        totalVideoCount: 0,
        processedVideoCount: 0,
        cacheHitCount: 0,
        isComplete: false,
        statusMessage: nil
    )

    let totalVideoCount: Int
    let processedVideoCount: Int
    let cacheHitCount: Int
    let isComplete: Bool
    let statusMessage: String?

    var progressFraction: Double? {
        guard totalVideoCount > 0 else { return nil }
        return min(
            max(
                Double(processedVideoCount) / Double(totalVideoCount),
                0
            ),
            1
        )
    }
}

struct FileScanUpdate: Sendable {
    let progress: FileScanProgress
    /// Nil on lightweight progress-only updates. Result collections publish at
    /// a lower cadence so a large library is not repeatedly sorted/reassigned.
    let largeFiles: [LargeFile]?
}

typealias FileRepresentativeResolver = @Sendable (
    _ asset: PHAsset
) async -> PHAssetRepresentativeFile

actor FileScanEngine {

    /// Tuning constant for the Large Videos product category.
    static let minimumFileSizeBytes: Int64 = 100 * 1024 * 1024
    static let measurementBatchSize = 8
    static let publicationBatchStride = 4

    private struct ResolvedVideo: Sendable {
        let file: LargeFile?
        let wasCached: Bool
    }

    private let authorizationProvider: FileScanAuthorizationProvider
    private let assetProvider: any FileScanAssetProviding
    private let representativeResolver: FileRepresentativeResolver

    init(
        authorizationProvider: FileScanAuthorizationProvider = .live,
        assetProvider: any FileScanAssetProviding = SystemFileScanAssetProvider(),
        representativeResolver: FileRepresentativeResolver? = nil
    ) {
        self.authorizationProvider = authorizationProvider
        self.assetProvider = assetProvider
        self.representativeResolver = representativeResolver ?? { asset in
            await asset.representativeFile()
        }
    }

    func scan(
        onUpdate: (@Sendable (FileScanUpdate) async -> Void)? = nil
    ) async throws -> [LargeFile] {
        try await requireReadAuthorization()
        return try await largePhotoAssets(onUpdate: onUpdate)
    }

    private func requireReadAuthorization() async throws {
        var status = authorizationProvider.currentStatus()
        if status == .notDetermined {
            // `.readWrite` is Photos' read-capable access level. Only prompt when
            // authorization has not yet been decided; repeat scans never re-prompt.
            status = await authorizationProvider.requestReadWrite()
        }

        guard status == .authorized || status == .limited else {
            throw FileScanError.permissionDenied(status)
        }
    }

    private func largePhotoAssets(
        onUpdate: (@Sendable (FileScanUpdate) async -> Void)?
    ) async throws -> [LargeFile] {
        let assets = await assetProvider.fetchVideoAssets()
        let totalVideoCount = assets.count
        // Scope the prune to videos. This scan only enumerated videos, so an
        // unscoped retain evicted every photo size measured elsewhere (the
        // export path), silently degrading deletion and reclaimable-space
        // figures to estimates on the next launch.
        await AssetFileSizeRepository.shared.retain(
            localIdentifiers: Set(assets.map(\.localIdentifier)),
            limitedTo: [.video]
        )

        await onUpdate?(
            FileScanUpdate(
                progress: FileScanProgress(
                    totalVideoCount: totalVideoCount,
                    processedVideoCount: 0,
                    cacheHitCount: 0,
                    isComplete: assets.isEmpty,
                    statusMessage: assets.isEmpty
                        ? "No videos found in your Photos library."
                        : "Preparing \(totalVideoCount.formatted()) videos…"
                ),
                largeFiles: assets.isEmpty ? [] : nil
            )
        )
        guard !assets.isEmpty else { return [] }

        var largeFiles: [LargeFile] = []
        var processedVideoCount = 0
        var cacheHitCount = 0
        for batchStart in stride(
            from: 0,
            to: assets.count,
            by: Self.measurementBatchSize
        ) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + Self.measurementBatchSize, assets.count)
            let batch = Array(assets[batchStart..<batchEnd])
            let resolvedVideos = await withTaskGroup(
                of: ResolvedVideo.self
            ) { group in
                for asset in batch {
                    group.addTask { [representativeResolver] in
                        let representative = await representativeResolver(asset)
                        let file = FileScanPolicy.qualifies(
                            byteSize: representative.byteSize
                        )
                            ? LargeFile(
                                id: UUID(),
                                source: .photoLibrary(asset: asset),
                                displayName: representative.displayName,
                                byteSize: representative.byteSize,
                                byteSizeIsEstimated: representative.byteSizeIsEstimated,
                                creationDate: asset.creationDate
                            )
                            : nil
                        return ResolvedVideo(
                            file: file,
                            wasCached: representative.wasCached
                        )
                    }
                }

                var videos: [ResolvedVideo] = []
                videos.reserveCapacity(batch.count)
                for await video in group {
                    videos.append(video)
                }
                return videos
            }
            try Task.checkCancellation()
            processedVideoCount += resolvedVideos.count
            cacheHitCount += resolvedVideos.reduce(into: 0) {
                $0 += $1.wasCached ? 1 : 0
            }
            largeFiles.append(
                contentsOf: resolvedVideos.compactMap(\.file)
            )
            let batchIndex = batchStart / Self.measurementBatchSize
            let isComplete = batchEnd == assets.count
            let shouldPublishResults = isComplete
                || (batchIndex + 1).isMultiple(of: Self.publicationBatchStride)
            let publishedFiles: [LargeFile]?
            if shouldPublishResults {
                largeFiles.sort { $0.byteSize > $1.byteSize }
                publishedFiles = largeFiles
            } else {
                publishedFiles = nil
            }
            await onUpdate?(
                FileScanUpdate(
                    progress: FileScanProgress(
                        totalVideoCount: totalVideoCount,
                        processedVideoCount: processedVideoCount,
                        cacheHitCount: cacheHitCount,
                        isComplete: isComplete,
                        statusMessage: Self.statusMessage(
                            processedVideoCount: processedVideoCount,
                            totalVideoCount: totalVideoCount,
                            cacheHitCount: cacheHitCount,
                            isComplete: isComplete
                        )
                    ),
                    largeFiles: publishedFiles
                )
            )
        }
        largeFiles.sort { $0.byteSize > $1.byteSize }
        return largeFiles
    }

    private static func statusMessage(
        processedVideoCount: Int,
        totalVideoCount: Int,
        cacheHitCount: Int,
        isComplete: Bool
    ) -> String {
        let checked = isComplete
            ? "Checked \(totalVideoCount.formatted()) videos"
            : "Checked \(processedVideoCount.formatted()) of \(totalVideoCount.formatted()) videos"
        guard cacheHitCount > 0 else { return checked }
        return "\(checked) · reused \(cacheHitCount.formatted()) saved sizes"
    }
}

enum FileScanPolicy {
    static func qualifies(byteSize: Int64) -> Bool {
        byteSize >= FileScanEngine.minimumFileSizeBytes
    }
}

struct CachedLargeVideoResult: Codable, Equatable, Sendable {
    let id: UUID
    let assetIdentifier: String
    let displayName: String
    let byteSize: Int64
    let byteSizeIsEstimated: Bool
    let creationDate: Date?
}

struct CachedLargeVideoSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let savedAt: Date
    let totalVideoCount: Int
    let results: [CachedLargeVideoResult]
}

struct RestoredLargeVideoResults: Sendable {
    let files: [LargeFile]
    let totalVideoCount: Int
    let missingResultCount: Int
}

/// Persists the completed Large Videos result set independently from app/build
/// versions. File-size measurements were already durable, but without this
/// index every relaunch still enumerated the entire video library.
actor LargeVideoResultCache {
    static let shared = LargeVideoResultCache()

    private let fileURL: URL
    private var cachedSnapshot: CachedLargeVideoSnapshot?
    private var hasLoaded = false

    init(directoryURL: URL? = nil) {
        let baseURL = directoryURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.temporaryDirectory
        fileURL = baseURL
            .appendingPathComponent("PhotoDuck", isDirectory: true)
            .appendingPathComponent("large-video-results.json")
    }

    func load() async -> CachedLargeVideoSnapshot? {
        if hasLoaded {
            return cachedSnapshot
        }
        hasLoaded = true
        let fileURL = fileURL
        cachedSnapshot = await Task.detached(priority: .utility) {
            guard let data = try? Data(
                contentsOf: fileURL,
                options: [.mappedIfSafe]
            ),
            let snapshot = try? JSONDecoder().decode(
                CachedLargeVideoSnapshot.self,
                from: data
            ),
            snapshot.schemaVersion == CachedLargeVideoSnapshot.schemaVersion
            else {
                return nil
            }
            return snapshot
        }.value
        return cachedSnapshot
    }

    func restoreFiles() async -> RestoredLargeVideoResults? {
        guard let snapshot = await load() else { return nil }
        let restored = await Task.detached(priority: .utility) {
            let identifiers = snapshot.results.map(\.assetIdentifier)
            let fetchResult = PHAsset.fetchAssets(
                withLocalIdentifiers: identifiers,
                options: nil
            )
            var assetsByID: [String: PHAsset] = [:]
            assetsByID.reserveCapacity(fetchResult.count)
            fetchResult.enumerateObjects { asset, _, _ in
                assetsByID[asset.localIdentifier] = asset
            }

            let files = snapshot.results.compactMap { record -> LargeFile? in
                guard let asset = assetsByID[record.assetIdentifier] else {
                    return nil
                }
                return LargeFile(
                    id: record.id,
                    source: .photoLibrary(asset: asset),
                    displayName: record.displayName,
                    byteSize: record.byteSize,
                    byteSizeIsEstimated: record.byteSizeIsEstimated,
                    creationDate: record.creationDate
                )
            }
            return RestoredLargeVideoResults(
                files: files,
                totalVideoCount: max(
                    snapshot.totalVideoCount
                        - (snapshot.results.count - files.count),
                    files.count
                ),
                missingResultCount: snapshot.results.count - files.count
            )
        }.value
        return restored
    }

    func save(files: [LargeFile], totalVideoCount: Int) async {
        let snapshot = CachedLargeVideoSnapshot(
            schemaVersion: CachedLargeVideoSnapshot.schemaVersion,
            savedAt: Date(),
            totalVideoCount: max(totalVideoCount, files.count),
            results: files.map { file in
                CachedLargeVideoResult(
                    id: file.id,
                    assetIdentifier: file.photoAsset.localIdentifier,
                    displayName: file.displayName,
                    byteSize: file.byteSize,
                    byteSizeIsEstimated: file.byteSizeIsEstimated,
                    creationDate: file.creationDate
                )
            }
        )
        cachedSnapshot = snapshot
        hasLoaded = true

        let fileURL = fileURL
        await Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                // This cache is an optimization. Explicit Refresh can rebuild
                // it if persistence is unavailable.
            }
        }.value
    }

    func remove(assetIdentifier: String) async {
        guard let snapshot = await load() else { return }
        let remaining = snapshot.results.filter {
            $0.assetIdentifier != assetIdentifier
        }
        guard remaining.count != snapshot.results.count else { return }
        let updated = CachedLargeVideoSnapshot(
            schemaVersion: snapshot.schemaVersion,
            savedAt: Date(),
            totalVideoCount: max(snapshot.totalVideoCount - 1, 0),
            results: remaining
        )
        cachedSnapshot = updated

        let fileURL = fileURL
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(updated) else { return }
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: fileURL, options: [.atomic])
        }.value
    }
}
