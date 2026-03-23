import Photos

struct PhotoGroup: Identifiable, @unchecked Sendable {
    let id: UUID
    let assets: [PHAsset]
    let similarity: Float
    let reason: SimilarityReason

    enum SimilarityReason: Sendable {
        case nearDuplicate
        case exactDuplicate
        case visuallySimilar
        case burstShot
    }
}

struct ScanProgress: Sendable {
    let phase: String
    let completed: Int
    let total: Int
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}
