import Photos
import UIKit
import CoreImage
import Accelerate

struct BlurAnalyzer {

    static func laplacianVariance(from cgImage: CGImage) -> Double? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

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
        var floatPixels = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            floatPixels[i] = Float(pixels[i])
        }

        let kernel: [Float] = [
            0,  1,  0,
            1, -4,  1,
            0,  1,  0
        ]

        var output = [Float](repeating: 0, count: width * height)
        floatPixels.withUnsafeBufferPointer { srcBuf in
            output.withUnsafeMutableBufferPointer { dstBuf in
                var srcBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcBuf.baseAddress!),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.size
                )
                var dstBuffer = vImage_Buffer(
                    data: dstBuf.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.size
                )
                kernel.withUnsafeBufferPointer { kBuf in
                    vImageConvolve_PlanarF(
                        &srcBuffer,
                        &dstBuffer,
                        nil,
                        0, 0,
                        kBuf.baseAddress!,
                        3, 3,
                        0,
                        vImage_Flags(kvImageEdgeExtend)
                    )
                }
            }
        }

        let count = width * height
        var mean: Float = 0
        var meanSq: Float = 0
        vDSP_meanv(output, 1, &mean, vDSP_Length(count))
        vDSP_measqv(output, 1, &meanSq, vDSP_Length(count))
        let variance = Double(meanSq - mean * mean)
        return variance
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
                            if isBlurry {
                                blurry.append(asset)
                            }
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
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
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
                let variance = BlurAnalyzer.laplacianVariance(from: cgImage) ?? Double.infinity
                continuation.resume(returning: variance < Self.blurThreshold)
            }
        }
    }
}
