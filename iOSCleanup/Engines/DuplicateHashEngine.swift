import Photos
import CoreGraphics

enum DuplicateScanEvent: Sendable {
    case progress(completed: Int, total: Int)
    case duplicatesFound([PhotoGroup])
}

actor DuplicateHashEngine {

    nonisolated func scan() -> AsyncThrowingStream<DuplicateScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await fetchAssets()
                    let total = assets.count
                    var completed = 0
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
                            if let hash {
                                hashes[id] = hash
                            }
                            completed += 1
                            continuation.yield(.progress(completed: completed, total: total))
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

                    let groups: [PhotoGroup] = buckets.values.compactMap { groupAssets in
                        guard groupAssets.count >= 2 else { return nil }
                        let sorted = groupAssets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                        return PhotoGroup(id: UUID(), assets: sorted, similarity: 0.0, reason: .exactDuplicate)
                    }

                    continuation.yield(.duplicatesFound(groups))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func fetchAssets() async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.permissionDenied
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaSubtype & %d == 0", PHAssetMediaSubtype.photoScreenshot.rawValue)

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    private func dHash(for asset: PHAsset) async -> UInt64? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 9, height: 8),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard let cgImage = image?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.computeDHash(from: cgImage))
            }
        }
    }

    private static func computeDHash(from cgImage: CGImage) -> UInt64? {
        let width = 9
        let height = 8
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        var hash: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let left = pixels[row * width + col]
                let right = pixels[row * width + col + 1]
                if left < right {
                    hash |= (1 << UInt64(row * 8 + col))
                }
            }
        }
        return hash
    }
}
