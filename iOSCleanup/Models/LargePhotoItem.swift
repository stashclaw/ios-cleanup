import Foundation
import Photos

/// A photo asset together with its on-disk file size, returned by `LargePhotoScanEngine`.
struct LargePhotoItem: Identifiable, @unchecked Sendable {
    let id: UUID
    let asset: PHAsset
    let byteSize: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}
