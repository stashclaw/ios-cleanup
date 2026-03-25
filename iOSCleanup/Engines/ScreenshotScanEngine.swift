import Photos

enum ScreenshotScanEvent: Sendable {
    case screenshotsFound([PHAsset])
}

actor ScreenshotScanEngine {

    nonisolated func scan(addedAfter: Date? = nil) -> AsyncThrowingStream<ScreenshotScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    guard status == .authorized || status == .limited else {
                        throw ScanError.permissionDenied
                    }

                    let options = PHFetchOptions()
                    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    var preds: [NSPredicate] = [
                        NSPredicate(format: "mediaSubtype & %d != 0",
                                    PHAssetMediaSubtype.photoScreenshot.rawValue)
                    ]
                    if let date = addedAfter {
                        preds.append(NSPredicate(format: "creationDate > %@", date as NSDate))
                    }
                    options.predicate = preds.count == 1 ? preds[0] : NSCompoundPredicate(andPredicateWithSubpredicates: preds)

                    let result = PHAsset.fetchAssets(with: .image, options: options)
                    var assets: [PHAsset] = []
                    result.enumerateObjects { asset, _, _ in assets.append(asset) }

                    continuation.yield(.screenshotsFound(assets))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
