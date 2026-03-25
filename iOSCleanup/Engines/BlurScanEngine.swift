import Photos
import UIKit
import CoreGraphics
import Accelerate
import Vision

struct BlurAnalyzer {

    // MARK: - Thresholds

    /// Face-region Laplacian variance below this → blurry face.
    private static let faceThreshold: Double = 55.0
    /// Global Laplacian variance below this → featureless scene (sky, walls). Skip.
    private static let textureGuardMin: Double = 8.0
    /// If p90 tile variance exceeds this → at least one sharp region exists → not blurry.
    private static let sharpRegionThreshold: Double = 420.0
    /// If p90/p10 tile ratio meets this → intentional depth-of-field → not blurry.
    private static let bokehSpreadRatio: Double = 4.0
    /// If p90 tile variance is below this → all tiles blurry → blurry.
    private static let globalBlurThreshold: Double = 260.0
    /// In the ambiguous zone, use p50 as tiebreaker.
    private static let ambiguousThreshold: Double = 120.0

    // MARK: - Public API

    /// Returns whether `cgImage` appears blurry.
    ///
    /// Algorithm: scales to 1024px long-edge, computes Laplacian variance over a 4×4 tile
    /// grid, then reasons about p10/p50/p90 of tile variances. Face-aware when observations
    /// are supplied: judges sharpness only within face bounding boxes to avoid bokeh false-positives.
    static func isBlurry(cgImage: CGImage, faces: [VNFaceObservation] = []) -> Bool {
        // Scale to 1024 on the long edge for consistent threshold behaviour.
        let maxSide = 1024
        let w0 = cgImage.width, h0 = cgImage.height
        let scale = min(1.0, Double(maxSide) / Double(max(w0, h0)))
        let width  = max(1, Int(Double(w0) * scale))
        let height = max(1, Int(Double(h0) * scale))

        let source: CGImage
        if scale < 1.0, let scaled = scaledGray(cgImage, width: width, height: height) {
            source = scaled
        } else {
            source = cgImage
        }

        guard width > 8, height > 8,
              let pixels = grayscaleFloats(from: source, width: width, height: height)
        else { return false }

        // Low-texture guard: featureless scenes (solid sky, blank walls) → not blurry.
        let globalVar = laplacianVariance(pixels: pixels, width: width, height: height)
        guard globalVar > textureGuardMin else { return false }

        // Face-aware path: judge sharpness within face regions only.
        if !faces.isEmpty {
            let maxFaceVar = faces.compactMap { obs -> Double? in
                let rect = pixelRect(for: obs, imageWidth: width, imageHeight: height)
                return regionVariance(pixels: pixels, imageWidth: width, region: rect)
            }.max() ?? globalVar
            return maxFaceVar < faceThreshold
        }

        // Tile-based analysis: 4×4 grid → 16 Laplacian variances.
        let raw = tileVariances(pixels: pixels, width: width, height: height)
        let tileVars = raw.sorted()
        guard tileVars.count >= 4 else {
            return globalVar < 80.0  // fallback for tiny images
        }

        let p10 = percentile(tileVars, 10)
        let p50 = percentile(tileVars, 50)
        let p90 = percentile(tileVars, 90)

        // Sharp region guard: at least one tile clearly sharp → photo is in focus somewhere.
        // Protects bokeh shots where the subject is sharp but background is blurred.
        if p90 > sharpRegionThreshold { return false }

        // Bokeh spread: large ratio between sharpest and blurriest tile
        // → intentional depth-of-field, not camera shake or focus miss.
        if p10 > 1.0, (p90 / p10) >= bokehSpreadRatio { return false }

        // Global blur: p90 below threshold → every tile is blurry.
        if p90 < globalBlurThreshold { return true }

        // Ambiguous zone: use median as tiebreaker.
        return p50 < ambiguousThreshold
    }

    /// Raw Laplacian variance of the full image (lower = blurrier).
    /// Kept for backwards compatibility with existing callers / tests.
    static func laplacianVariance(from cgImage: CGImage) -> Double {
        let width  = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2,
              let pixels = grayscaleFloats(from: cgImage, width: width, height: height)
        else { return 0 }
        return laplacianVariance(pixels: pixels, width: width, height: height)
    }

    // MARK: - Private helpers

    /// Renders `cgImage` to a grayscale CGImage at the given dimensions.
    private static func scaledGray(_ src: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Renders `cgImage` to a flat grayscale [Float] buffer via vDSP (hardware-accelerated).
    private static func grayscaleFloats(from cgImage: CGImage, width: Int, height: Int) -> [Float]? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }
        let src = data.bindMemory(to: UInt8.self, capacity: width * height)
        var floats = [Float](repeating: 0, count: width * height)
        vDSP_vfltu8(src, 1, &floats, 1, vDSP_Length(width * height))
        return floats
    }

    /// Applies a 3×3 Laplacian kernel and returns variance of the response (hardware-accelerated).
    private static func laplacianVariance(pixels: [Float], width: Int, height: Int) -> Double {
        let innerW = width  - 2
        let innerH = height - 2
        let count  = innerW * innerH
        guard count > 0 else { return 0 }

        var laps = [Float](repeating: 0, count: count)
        for row in 1..<(height - 1) {
            for col in 1..<(width - 1) {
                let i = row * width + col
                laps[(row - 1) * innerW + (col - 1)] =
                    4 * pixels[i]
                    - pixels[i - width] - pixels[i + width]
                    - pixels[i - 1]     - pixels[i + 1]
            }
        }
        var mean: Float   = 0
        var meanSq: Float = 0
        vDSP_meanv(&laps, 1, &mean,   vDSP_Length(count))
        vDSP_measqv(&laps, 1, &meanSq, vDSP_Length(count))
        return Double(meanSq - mean * mean)
    }

    /// Computes Laplacian variance for each tile in a `rows × cols` grid.
    private static func tileVariances(
        pixels: [Float], width: Int, height: Int,
        rows: Int = 4, cols: Int = 4
    ) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(rows * cols)
        let tileW = width / cols
        let tileH = height / rows
        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = c * tileW, y0 = r * tileH
                let x1 = min(x0 + tileW, width)
                let y1 = min(y0 + tileH, height)
                let region = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                if let v = regionVariance(pixels: pixels, imageWidth: width, region: region) {
                    result.append(v)
                }
            }
        }
        return result
    }

    /// Returns the value at percentile `p` (0–100) of an already-sorted array.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = max(0, min(sorted.count - 1,
                             Int((p / 100.0) * Double(sorted.count - 1) + 0.5)))
        return sorted[idx]
    }

    /// Converts a Vision `boundingBox` (normalised, origin bottom-left) to pixel coordinates.
    private static func pixelRect(for obs: VNFaceObservation,
                                  imageWidth: Int, imageHeight: Int) -> CGRect {
        let bb = obs.boundingBox
        return CGRect(
            x:      bb.minX  * Double(imageWidth),
            y:      (1.0 - bb.maxY) * Double(imageHeight),
            width:  bb.width  * Double(imageWidth),
            height: bb.height * Double(imageHeight)
        )
    }

    /// Computes Laplacian variance within a pixel sub-region of the grayscale buffer.
    private static func regionVariance(pixels: [Float],
                                       imageWidth: Int,
                                       region: CGRect) -> Double? {
        let imageHeight = pixels.count / imageWidth
        let x0 = max(1, Int(region.minX))
        let y0 = max(1, Int(region.minY))
        let x1 = min(imageWidth  - 2, Int(region.maxX))
        let y1 = min(imageHeight - 2, Int(region.maxY))
        guard x1 > x0 + 2, y1 > y0 + 2 else { return nil }

        let count = (x1 - x0) * (y1 - y0)
        var laps  = [Float](repeating: 0, count: count)
        var idx   = 0
        for row in y0..<y1 {
            for col in x0..<x1 {
                let i = row * imageWidth + col
                laps[idx] =
                    4 * pixels[i]
                    - pixels[i - imageWidth] - pixels[i + imageWidth]
                    - pixels[i - 1]          - pixels[i + 1]
                idx += 1
            }
        }
        var mean: Float   = 0
        var meanSq: Float = 0
        vDSP_meanv(&laps, 1, &mean,   vDSP_Length(count))
        vDSP_measqv(&laps, 1, &meanSq, vDSP_Length(count))
        return Double(meanSq - mean * mean)
    }
}

// MARK: -

enum BlurScanEvent: Sendable {
    case progress(completed: Int, total: Int)
    case blurryPhotosFound([PHAsset])
}

actor BlurScanEngine {

    nonisolated func scan(addedAfter: Date? = nil) -> AsyncThrowingStream<BlurScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets  = try await fetchAssets(addedAfter: addedAfter)
                    let total   = assets.count
                    var completed = 0
                    var blurry: [PHAsset] = []

                    await withTaskGroup(of: (PHAsset, Bool).self) { group in
                        var nextIndex = 0
                        var inFlight  = 0

                        while inFlight < 4, nextIndex < assets.count {
                            let a = assets[nextIndex]; nextIndex += 1
                            group.addTask { await self.checkBlur(asset: a) }
                            inFlight += 1
                        }

                        for await (asset, isBlurry) in group {
                            if isBlurry { blurry.append(asset) }
                            completed += 1
                            continuation.yield(.progress(completed: completed, total: total))
                            if nextIndex < assets.count {
                                let a = assets[nextIndex]; nextIndex += 1
                                group.addTask { await self.checkBlur(asset: a) }
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

    // MARK: - Private

    private func fetchAssets(addedAfter: Date? = nil) async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.permissionDenied
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Skip screenshots — they're never blurry by definition.
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

    /// Loads the image at 1024px (matching BlurAnalyzer's internal scale),
    /// detects faces, then evaluates blur — all in one actor call.
    private func checkBlur(asset: PHAsset) async -> (PHAsset, Bool) {
        guard let cgImage = await loadImage(asset: asset) else { return (asset, false) }
        let faces    = detectFaces(in: cgImage)
        let isBlurry = BlurAnalyzer.isBlurry(cgImage: cgImage, faces: faces)
        return (asset, isBlurry)
    }

    private func loadImage(asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1024, height: 1024),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    /// VNDetectFaceRectanglesRequest — fast cascade detector, typically <20 ms on A-series.
    private func detectFaces(in cgImage: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return request.results ?? []
    }
}
