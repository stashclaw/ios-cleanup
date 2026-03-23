import Photos
import CoreGraphics

enum BlurScanEvent: Sendable {
    case progress(completed: Int, total: Int)
    case blurryFound([PhotoGroup])
}

actor BlurScanEngine {

    /// Laplacian variance below this threshold is considered blurry.
    private static let blurThreshold: Float = 80.0

    nonisolated func scan() -> AsyncThrowingStream<BlurScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await fetchAssets()
                    let total = assets.count
                    var completed = 0
                    var blurryAssets: [PHAsset] = []

                    await withTaskGroup(of: (PHAsset, Bool).self) { group in
                        var nextIndex = 0
                        var inFlight = 0

                        while inFlight < 4, nextIndex < assets.count {
                            let a = assets[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                let blurry = await self.isBlurry(a)
                                return (a, blurry)
                            }
                            inFlight += 1
                        }

                        for await (asset, blurry) in group {
                            if blurry { blurryAssets.append(asset) }
                            completed += 1
                            continuation.yield(.progress(completed: completed, total: total))
                            if nextIndex < assets.count {
                                let a = assets[nextIndex]
                                nextIndex += 1
                                group.addTask {
                                    let blurry = await self.isBlurry(a)
                                    return (a, blurry)
                                }
                            }
                        }
                    }

                    let groups = blurryAssets.map { asset in
                        PhotoGroup(id: UUID(), assets: [asset], similarity: 0.0, reason: .blurry)
                    }
                    continuation.yield(.blurryFound(groups))
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
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func isBlurry(_ asset: PHAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 200, height: 200),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                guard let cgImage = image?.cgImage else {
                    continuation.resume(returning: false)
                    return
                }
                let variance = Self.laplacianVariance(cgImage)
                continuation.resume(returning: variance < Self.blurThreshold)
            }
        }
    }

    /// Computes the variance of a discrete Laplacian (3×3 kernel) over the
    /// grayscale image. Lower variance → less edge detail → blurrier image.
    private static func laplacianVariance(_ cgImage: CGImage) -> Float {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 2, h > 2,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return 0 }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)

        var sum: Float = 0
        var sumSq: Float = 0
        let count = Float((w - 2) * (h - 2))

        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let lap = Float(
                    Int(px[(y-1)*w + x]) +
                    Int(px[(y+1)*w + x]) +
                    Int(px[y*w + (x-1)]) +
                    Int(px[y*w + (x+1)]) -
                    4 * Int(px[y*w + x])
                )
                sum += lap
                sumSq += lap * lap
            }
        }
        let mean = sum / count
        return sumSq / count - mean * mean
    }
}
