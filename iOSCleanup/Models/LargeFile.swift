import Foundation
import Photos

struct LargeFile: Identifiable, Sendable {
    let id: UUID
    let source: Source
    let displayName: String
    let byteSize: Int64
    let byteSizeIsEstimated: Bool
    let creationDate: Date?

    enum Source: Sendable {
        case photoLibrary(asset: PHAsset)
    }

    init(
        id: UUID,
        source: Source,
        displayName: String,
        byteSize: Int64,
        byteSizeIsEstimated: Bool = false,
        creationDate: Date?
    ) {
        self.id = id
        self.source = source
        self.displayName = displayName
        self.byteSize = byteSize
        self.byteSizeIsEstimated = byteSizeIsEstimated
        self.creationDate = creationDate
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var photoAsset: PHAsset {
        switch source {
        case .photoLibrary(let asset):
            return asset
        }
    }
}
