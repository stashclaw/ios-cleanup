import Foundation
import Photos
import Vision
import UIKit

// MARK: - Quality label

enum PhotoQualityLabel: String, Sendable {
    case blurry         = "Blurry"
    case eyesClosed     = "Eyes Closed"
    case underexposed   = "Too Dark"
    case overexposed    = "Overexposed"
    case lowFaceQuality = "Low Quality"
    case noSubject      = "No Subject"   // No salient region detected — likely accidental or empty scene

    var icon: String {
        switch self {
        case .blurry:         return "camera.filters"
        case .eyesClosed:     return "eye.slash"
        case .underexposed:   return "moon.fill"
        case .overexposed:    return "sun.max.fill"
        case .lowFaceQuality: return "face.dashed"
        case .noSubject:      return "eye.slash"
        }
    }
}

// MARK: - Analyzer

actor PhotoQualityAnalyzer {
    static let shared = PhotoQualityAnalyzer()
    private var cache: [String: [PhotoQualityLabel]] = [:]
    private var scoreCache: [String: Float] = [:]

    func labels(for asset: PHAsset) async -> [PhotoQualityLabel] {
        if let hit = cache[asset.localIdentifier] { return hit }
        let result = await computeLabels(asset)
        cache[asset.localIdentifier] = result
        return result
    }

    /// Returns a composite quality score 0.0–1.0 (higher = better quality, keep this one).
    /// Factors: face capture quality, blur, exposure, eyes-closed penalty.
    func qualityScore(for asset: PHAsset) async -> Float {
        if let hit = scoreCache[asset.localIdentifier] { return hit }
        let qualityLabels = await labels(for: asset)
        var score: Float = 0.5
        if qualityLabels.contains(.blurry)         { score -= 0.3  }
        if qualityLabels.contains(.eyesClosed)      { score -= 0.2  }
        if qualityLabels.contains(.underexposed)    { score -= 0.15 }
        if qualityLabels.contains(.overexposed)     { score -= 0.15 }
        if qualityLabels.contains(.lowFaceQuality)  { score -= 0.2  }
        let clamped = min(1.0, max(0.0, score))
        scoreCache[asset.localIdentifier] = clamped
        return clamped
    }

    // MARK: - Top-level pipeline

    private func computeLabels(_ asset: PHAsset) async -> [PhotoQualityLabel] {
        guard let uiImage = await fetchThumbnail(asset),
              let cgImage = uiImage.cgImage else { return [] }

        var labels: [PhotoQualityLabel] = []

        if isBlurry(cgImage) { labels.append(.blurry) }

        let lum = meanLuminance(cgImage)
        if lum < 0.12      { labels.append(.underexposed) }
        else if lum > 0.93 { labels.append(.overexposed) }

        labels.append(contentsOf: faceQualityLabels(cgImage))

        // Saliency check — no salient objects means likely accidental/empty shot
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let saliencyHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? saliencyHandler.perform([saliencyRequest])
        if let saliencyResult = saliencyRequest.results?.first as? VNSaliencyImageObservation {
            let salientObjects = saliencyResult.salientObjects ?? []
            if salientObjects.isEmpty {
                labels.append(.noSubject)
            }
        }

        return labels
    }

    // MARK: - Thumbnail fetch

    private func fetchThumbnail(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 300, height: 300),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in continuation.resume(returning: image) }
        }
    }

    // MARK: - Blur (Laplacian variance, adaptive threshold)

    private func isBlurry(_ image: CGImage) -> Bool {
        let w = min(image.width, 200), h = min(image.height, 200)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let ptr = ctx.data else { return false }
        let buf = ptr.bindMemory(to: UInt8.self, capacity: w * h)

        // Compute mean luminance (0–255) from the same grayscale buffer.
        // Reusing this pass avoids a second render. Mean luminance is used
        // to build an adaptive threshold: dark/night shots have lower Laplacian
        // variance even when sharp (fewer bright edges), so they need a lower
        // threshold to avoid being falsely flagged as blurry.
        var pixelSum: Double = 0
        let pixelTotal = w * h
        for i in 0..<pixelTotal { pixelSum += Double(buf[i]) }
        let meanLuminance = pixelTotal > 0 ? pixelSum / Double(pixelTotal) : 128.0

        // Adaptive threshold: scales from ~26 (very dark) to 80 (fully bright).
        // Formula: threshold = 80 * (0.33 + 0.67 * brightnessFactor)
        // At meanLuminance =   0 (black): threshold ≈ 26
        // At meanLuminance = 255 (white): threshold  = 80
        let brightnessFactor = meanLuminance / 255.0
        let adaptiveThreshold = 80.0 * (0.33 + 0.67 * brightnessFactor)

        var sumSq: Double = 0
        var n = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = 4.0 * Double(buf[i])
                    - Double(buf[i - 1]) - Double(buf[i + 1])
                    - Double(buf[i - w]) - Double(buf[i + w])
                sumSq += lap * lap
                n += 1
            }
        }
        return n > 0 && (sumSq / Double(n)) < adaptiveThreshold
    }

    // MARK: - Exposure (mean luminance)

    private func meanLuminance(_ image: CGImage) -> Double {
        let w = 60, h = 60
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0.5 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let ptr = ctx.data else { return 0.5 }
        let buf = ptr.bindMemory(to: UInt8.self, capacity: w * h)
        var total: Double = 0
        for i in 0..<(w * h) { total += Double(buf[i]) }
        return total / Double(w * h) / 255.0
    }

    // MARK: - Face analysis (Vision — synchronous within actor)

    private func faceQualityLabels(_ image: CGImage) -> [PhotoQualityLabel] {
        var labels: [PhotoQualityLabel] = []
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let landmarksReq = VNDetectFaceLandmarksRequest()
        let qualityReq   = VNDetectFaceCaptureQualityRequest()
        try? handler.perform([landmarksReq, qualityReq])

        // Eyes-closed: bounding-box aspect ratio of eye landmarks
        if let faces = landmarksReq.results as? [VNFaceObservation] {
            for face in faces {
                guard let lm = face.landmarks else { continue }
                let leftEAR  = eyeAspect(lm.leftEye)
                let rightEAR = eyeAspect(lm.rightEye)
                if leftEAR < 0.15 && rightEAR < 0.15 {
                    labels.append(.eyesClosed)
                    break
                }
            }
        }

        // Low face capture quality (iOS 14.5+)
        if !labels.contains(.eyesClosed),
           let faces = qualityReq.results as? [VNFaceObservation] {
            for face in faces {
                if let q = face.faceCaptureQuality, q < 0.25 {
                    labels.append(.lowFaceQuality)
                    break
                }
            }
        }

        return labels
    }

    /// Height/width ratio of the eye landmark bounding box.
    /// Closed eyes produce a very flat box (ratio < 0.15).
    private func eyeAspect(_ region: VNFaceLandmarkRegion2D?) -> Double {
        guard let region else { return 1.0 }
        let pts = region.normalizedPoints
        guard pts.count >= 4 else { return 1.0 }
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let w = Double(maxX - minX)
        let h = Double(maxY - minY)
        guard w > 0.01 else { return 1.0 }
        return h / w
    }
}
