import Photos
import UIKit
import CoreGraphics

struct BlurAnalyzer {

    /// Returns the Laplacian variance of a grayscale image — lower = blurrier.
    static func laplacianVariance(from cgImage: CGImage) -> Double {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2 else { return 0 }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return 0 }

        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        // 3×3 Laplacian kernel: centre - 4 neighbours
        var sum: Double = 0
        var sumSq: Double = 0
        let count = (width - 2) * (height - 2)

        for row in 1..<(height - 1) {
            for col in 1..<(width - 1) {
                let c = Int(pixels[row * width + col])
                let n = Int(pixels[(row - 1) * width + col])
                let s = Int(pixels[(row + 1) * width + col])
                let w = Int(pixels[row * width + (col - 1)])
                let e = Int(pixels[row * width + (col + 1)])
                let lap = Double(4 * c - n - s - w - e)
                sum += lap
                sumSq += lap * lap
            }
        }

        let mean = sum / Double(count)
        return sumSq / Double(count) - mean * mean
    }
}

enum BlurScanEvent: Sendable {
    case progress(completed: Int, total: Int)
    case blurryPhotosFound([PHAsset])
}

actor BlurScanEngine {

    private static let blurThreshold: Double = 100.0

    nonisolated func scan() -> AsyncThrowingStream<BlurScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await fetchAssets()
                    let total = assets.count
                    var completed = 0
                    var blurry: [PHAsset] = []

                    await withTaskGroup(of: (PHAsset, Bool).self) { group in
                        var nextIndex = 0
                        var inFlight = 0

                        while inFlight < 4, nextIndex < assets.count {
                            let a = assets[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                let isBlurry = await self.isBlurry(asset: a)
                                return (a, isBlurry)
                            }
                            inFlight += 1
                        }

                        for await (asset, isBlurry) in group {
                            if isBlurry { blurry.append(asset) }
                            completed += 1
                            continuation.yield(.progress(completed: completed, total: total))
                            if nextIndex < assets.count {
                                let a = assets[nextIndex]
                                nextIndex += 1
                                group.addTask {
                                    let isBlurry = await self.isBlurry(asset: a)
                                    return (a, isBlurry)
                                }
                            }
                        }
                    }

                    continuation.yield(.blurryPhotosFound(blurry))
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
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func isBlurry(asset: PHAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 512, height: 512),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                guard let cgImage = image?.cgImage else {
                    continuation.resume(returning: false)
                    return
                }
                let variance = BlurAnalyzer.laplacianVariance(from: cgImage)
                continuation.resume(returning: variance < Self.blurThreshold)
            }
        }
    }
}
