import Photos

struct VideoGroup: Identifiable, @unchecked Sendable {
    let id: UUID
    let assets: [PHAsset]    // assets[0] = largest/best quality, rest are duplicates
    let totalBytes: Int64    // sum of all assets' file sizes
    let reason: VideoGroupReason
}

enum VideoGroupReason: Sendable {
    case nearDuplicate   // similar keyframes, likely same video recorded twice
    case exactDuplicate  // identical first-frame hash
}
