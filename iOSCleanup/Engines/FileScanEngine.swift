import Foundation
import Photos

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

    static let minimumFileSizeBytes: Int64 = 50 * 1024 * 1024  // 50 MB

    private let authorizationProvider: FileScanAuthorizationProvider

    init(authorizationProvider: FileScanAuthorizationProvider = .live) {
        self.authorizationProvider = authorizationProvider
    }

    func scan() async throws -> [LargeFile] {
        try await requireReadAuthorization()
        return try await largePhotoAssets().sorted { $0.byteSize > $1.byteSize }
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

    private func largePhotoAssets() async throws -> [LargeFile] {
        let result = PHAsset.fetchAssets(with: .video, options: nil)

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        var largeFiles: [LargeFile] = []
        for asset in assets {
            try Task.checkCancellation()
            let representative = await asset.representativeFile()
            guard representative.byteSize >= FileScanEngine.minimumFileSizeBytes else { continue }
            largeFiles.append(
                LargeFile(
                    id: UUID(),
                    source: .photoLibrary(asset: asset),
                    displayName: representative.displayName,
                    byteSize: representative.byteSize,
                    byteSizeIsEstimated: representative.byteSizeIsEstimated,
                    creationDate: asset.creationDate
                )
            )
        }
        return largeFiles
    }
}
