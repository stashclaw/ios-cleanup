import Photos
import UIKit
import CoreGraphics

enum DuplicateScanEvent: Sendable {
    case progress(completed: Int, total: Int)
    case duplicatesFound([PhotoGroup])
}

actor DuplicateHashEngine {

    private let imageLoader: any ImageLoader

    init(imageLoader: any ImageLoader = PHImageLoader()) {
        self.imageLoader = imageLoader
    }

    nonisolated func scan(addedAfter: Date? = nil) -> AsyncThrowingStream<DuplicateScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await fetchAssets(addedAfter: addedAfter)
                    guard !Task.isCancelled else { continuation.finish(); return }

                    let total = assets.count
                    let counter = ThreadSafeCounter()
                    let throttle = ProgressThrottle(every: 40)
                    var hashes: [String: UInt64] = [:]

                    await withTaskGroup(of: (String, UInt64?).self) { group in
                        var nextIndex = 0
                        var inFlight = 0

                        while inFlight < 4, nextIndex < assets.count {
                            let a = assets[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                let hash = await self.dHash(for: a)
                                return (a.localIdentifier, hash)
                            }
                            inFlight += 1
                        }

                        for await (id, hash) in group {
                            guard !Task.isCancelled else { group.cancelAll(); return }
                            if let hash { hashes[id] = hash }
                            let completed = counter.increment()
                            if throttle.shouldReport(completed: completed) {
                                continuation.yield(.progress(completed: completed, total: total))
                            }
                            if nextIndex < assets.count {
                                let a = assets[nextIndex]
                                nextIndex += 1
                                group.addTask {
                                    let hash = await self.dHash(for: a)
                                    return (a.localIdentifier, hash)
                                }
                            }
                        }
                    }

                    var buckets: [UInt64: [PHAsset]] = [:]
                    for asset in assets {
                        guard let hash = hashes[asset.localIdentifier] else { continue }
                        buckets[hash, default: []].append(asset)
                    }

                    // Sort within each group: best resolution first, then most recent.
                    // Sort groups themselves by most recent photo so newest duplicates surface first.
                    let groups: [PhotoGroup] = buckets.values
                        .compactMap { groupAssets -> PhotoGroup? in
                            guard groupAssets.count >= 2 else { return nil }
                            let sorted = groupAssets.sorted {
                                let lPx = $0.pixelWidth * $0.pixelHeight
                                let rPx = $1.pixelWidth * $1.pixelHeight
                                if lPx != rPx { return lPx > rPx }
                                return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
                            }
                            return PhotoGroup(id: UUID(), assets: sorted, similarity: 0.0, reason: .exactDuplicate)
                        }
                        .sorted {
                            ($0.assets.compactMap(\.creationDate).max() ?? .distantPast) >
                            ($1.assets.compactMap(\.creationDate).max() ?? .distantPast)
                        }

                    continuation.yield(.duplicatesFound(groups))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func fetchAssets(addedAfter: Date? = nil) async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.permissionDenied
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var preds: [NSPredicate] = [
            NSPredicate(format: "mediaSubtype & %d == 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        ]
        if let date = addedAfter {
            preds.append(NSPredicate(format: "creationDate > %@", date as NSDate))
        }
        options.predicate = preds.count == 1 ? preds[0] : NSCompoundPredicate(andPredicateWithSubpredicates: preds)

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func dHash(for asset: PHAsset) async -> UInt64? {
        await withCheckedContinuation { continuation in
            var didResume = false

            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            imageLoader.requestImage(
                for: asset,
                targetSize: CGSize(width: 9, height: 8),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard !didResume else { return }
                didResume = true
                guard let cgImage = image?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.computeDHash(from: cgImage))
            }
        }
    }

    private static func computeDHash(from cgImage: CGImage) -> UInt64? {
        let width = 9, height = 8
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        var hash: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                if pixels[row * width + col] < pixels[row * width + col + 1] {
                    hash |= (1 << UInt64(row * 8 + col))
                }
            }
        }
        return hash
    }
}
