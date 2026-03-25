import Photos

// MARK: - Event

enum LargePhotoScanEvent: Sendable {
    case progress(completed: Int, total: Int)
    case photosFound([LargePhotoItem])
}

// MARK: - Engine

actor LargePhotoScanEngine {

    /// Photos at or above this threshold are surfaced (RAW ≥ 25 MB, ProRAW ≥ 40 MB, panoramas ~8 MB+).
    static let thresholdBytes: Int64 = 10 * 1024 * 1024   // 10 MB

    nonisolated func scan(addedAfter: Date? = nil) -> AsyncThrowingStream<LargePhotoScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await self.fetchAssets(addedAfter: addedAfter)
                    let total  = assets.count
                    var results: [LargePhotoItem] = []

                    for (index, asset) in assets.enumerated() {
                        guard !Task.isCancelled else { break }

                        if let size = Self.fileSize(for: asset), size >= LargePhotoScanEngine.thresholdBytes {
                            results.append(LargePhotoItem(id: UUID(), asset: asset, byteSize: size))
                        }

                        let completed = index + 1
                        // Emit progress every 100 assets or on the last one.
                        if completed % 100 == 0 || completed == total {
                            continuation.yield(.progress(completed: completed, total: total))
                        }
                    }

                    // Sort biggest first so the highest-impact items are visible immediately.
                    results.sort { $0.byteSize > $1.byteSize }
                    continuation.yield(.photosFound(results))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func fetchAssets(addedAfter: Date? = nil) async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.permissionDenied
        }
        let options = PHFetchOptions()
        var preds: [NSPredicate] = [
            NSPredicate(format: "mediaSubtype & %d == 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        ]
        if let date = addedAfter {
            preds.append(NSPredicate(format: "creationDate > %@", date as NSDate))
        }
        options.predicate = preds.count == 1 ? preds[0] : NSCompoundPredicate(andPredicateWithSubpredicates: preds)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Returns the primary resource file size for `asset`, or nil if unavailable.
    /// Uses the private KVC key "fileSize" on `PHAssetResource`; works even when the
    /// asset is not fully downloaded locally (the size is stored in the library metadata).
    private static func fileSize(for asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the full-size photo resource; fall back to any resource.
        let primary = resources.first(where: { $0.type == .photo }) ?? resources.first
        return primary.flatMap { $0.value(forKey: "fileSize") as? Int64 }
    }
}
