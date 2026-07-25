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
        await AssetFileSizeRepository.shared.retain(
            localIdentifiers: Set(assets.map(\.localIdentifier))
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
