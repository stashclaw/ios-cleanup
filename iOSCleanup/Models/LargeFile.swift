import Foundation
import Photos

struct LargeFile: Identifiable, @unchecked Sendable {
    let id: UUID
    let source: Source
    let displayName: String
    let byteSize: Int64
    let creationDate: Date?

    enum Source: @unchecked Sendable {
        case photoLibrary(asset: PHAsset)
        case filesystem(url: URL)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}
