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

actor FileScanEngine {

    /// Tuning constant for the Large Videos product category.
    static let minimumFileSizeBytes: Int64 = 100 * 1024 * 1024
    static let measurementBatchSize = 8

    private let authorizationProvider: FileScanAuthorizationProvider

    init(authorizationProvider: FileScanAuthorizationProvider = .live) {
        self.authorizationProvider = authorizationProvider
    }

    func scan(
        onUpdate: (@Sendable ([LargeFile]) async -> Void)? = nil
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
        onUpdate: (@Sendable ([LargeFile]) async -> Void)?
    ) async throws -> [LargeFile] {
        let result = PHAsset.fetchAssets(with: .video, options: nil)

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        var largeFiles: [LargeFile] = []
        for batchStart in stride(
            from: 0,
            to: assets.count,
            by: Self.measurementBatchSize
        ) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + Self.measurementBatchSize, assets.count)
            let batch = Array(assets[batchStart..<batchEnd])
            let measuredFiles = await withTaskGroup(of: LargeFile?.self) { group in
                for asset in batch {
                    group.addTask {
                        let representative = await asset.representativeFile()
                        guard FileScanPolicy.qualifies(
                            byteSize: representative.byteSize
                        ) else {
                            return nil
                        }
                        return LargeFile(
                            id: UUID(),
                            source: .photoLibrary(asset: asset),
                            displayName: representative.displayName,
                            byteSize: representative.byteSize,
                            byteSizeIsEstimated: representative.byteSizeIsEstimated,
                            creationDate: asset.creationDate
                        )
                    }
                }

                var files: [LargeFile] = []
                for await file in group {
                    if let file {
                        files.append(file)
                    }
                }
                return files
            }
            largeFiles.append(contentsOf: measuredFiles)
            largeFiles.sort { $0.byteSize > $1.byteSize }
            await onUpdate?(largeFiles)
        }
        return largeFiles
    }
}

enum FileScanPolicy {
    static func qualifies(byteSize: Int64) -> Bool {
        byteSize >= FileScanEngine.minimumFileSizeBytes
    }
}
