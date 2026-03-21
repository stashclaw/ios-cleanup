import Photos

extension PHAsset {
    /// Returns the best available file-size estimate for this asset.
    ///
    /// Reads the actual byte count from PHAssetResource metadata — a synchronous
    /// call that requires no file I/O. Falls back to a compression-adjusted pixel
    /// estimate (~8:1 ratio) when metadata is unavailable (e.g. iCloud-only assets
    /// whose resource records have not yet synced locally).
    var estimatedFileSize: Int64 {
        let resources = PHAssetResource.assetResources(for: self)
        let photoTypes: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto]
        let resource = resources.first { photoTypes.contains($0.type) } ?? resources.first
        if let resource,
           let size = resource.value(forKey: "fileSize") as? CLongLong,
           size > 0 {
            return size
        }
        // Fallback: conservative compression estimate for HEIC/JPEG.
        // Typical compression is ~10–15:1 vs raw pixels; dividing by 8 stays safely
        // above the average so we never dramatically undercount potential savings.
        return max(Int64(pixelWidth) * Int64(pixelHeight) / 8, 0)
    }
}
