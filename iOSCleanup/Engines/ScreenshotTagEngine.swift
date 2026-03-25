@preconcurrency import Vision
import Photos
import UIKit

// MARK: - ScreenshotTag

enum ScreenshotTag: String, CaseIterable, Sendable {
    case receipt      = "Receipt"
    case boardingPass = "Boarding Pass"
    case coupon       = "Coupon / Code"
    case meme         = "Meme"
    case conversation = "Conversation"
    case other        = "Other"

    var icon: String {
        switch self {
        case .receipt:      return "doc.text"
        case .boardingPass: return "airplane"
        case .coupon:       return "tag"
        case .meme:         return "face.smiling"
        case .conversation: return "message"
        case .other:        return "photo"
        }
    }
}

// MARK: - ScreenshotTagEvent

enum ScreenshotTagEvent: Sendable {
    case progress(completed: Int, total: Int)
    case tagsFound([String: ScreenshotTag])   // key = asset.localIdentifier
}

// MARK: - ScreenshotTagEngine

actor ScreenshotTagEngine {

    nonisolated func tag(assets: [PHAsset]) -> AsyncThrowingStream<ScreenshotTagEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let total = assets.count
                guard total > 0 else { continuation.finish(); return }

                // Sliding window: process up to 4 assets concurrently.
                let windowSize = 4
                var completed = 0
                var results: [String: ScreenshotTag] = [:]

                // Chunk into windows to keep concurrency bounded.
                var index = 0
                while index < total {
                    let end = min(index + windowSize, total)
                    let batch = Array(assets[index..<end])

                    await withTaskGroup(of: (String, ScreenshotTag).self) { group in
                        for asset in batch {
                            group.addTask {
                                let tag = await Self.classify(asset: asset)
                                return (asset.localIdentifier, tag)
                            }
                        }
                        for await (identifier, tag) in group {
                            results[identifier] = tag
                            completed += 1
                            if completed % 20 == 0 || completed == total {
                                continuation.yield(.progress(completed: completed, total: total))
                            }
                        }
                    }
                    index = end
                }

                continuation.yield(.tagsFound(results))
                continuation.finish()
            }
        }
    }

    // MARK: - Private helpers

    private static func classify(asset: PHAsset) async -> ScreenshotTag {
        guard let image = await loadThumbnail(asset: asset) else { return .other }
        let lines = await recognizeText(in: image)
        return classify(lines: lines)
    }

    private static func loadThumbnail(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.resizeMode = .fast
            opts.isSynchronous = false
            let targetSize = CGSize(width: 512, height: 512)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: opts
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static func recognizeText(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    private static func classify(lines: [String]) -> ScreenshotTag {
        let joined = lines.joined(separator: " ").lowercased()
        let totalChars = joined.replacingOccurrences(of: " ", with: "").count

        // Receipt
        let receiptKeywords = ["total", "subtotal", "receipt", "tax", "payment",
                               "order #", "invoice", "amount due", "tip"]
        if receiptKeywords.contains(where: { joined.contains($0) }) {
            return .receipt
        }

        // Boarding pass
        let boardingKeywords = ["boarding pass", "gate", "seat", "flight",
                                "departure", "arrival", "passenger", "terminal"]
        if boardingKeywords.contains(where: { joined.contains($0) }) {
            return .boardingPass
        }

        // Coupon / promo code
        let couponKeywords = ["% off", "discount", "promo", "coupon", "code:",
                              "redeem", "expires", "save $", "offer"]
        if couponKeywords.contains(where: { joined.contains($0) }) {
            return .coupon
        }

        // Meme: very short text or classic meme phrases
        let memePhrases = ["when you", "me:", "them:", "nobody:", "literally", "be like"]
        if totalChars < 15 && !lines.isEmpty {
            return .meme
        }
        if memePhrases.contains(where: { joined.contains($0) }) {
            return .meme
        }

        // Conversation: many short lines with messaging cues
        let shortLines = lines.filter { $0.count < 50 }
        let messagingCues = ["read", "delivered", "typing", " am", " pm"]
        if shortLines.count > 5 && messagingCues.contains(where: { joined.contains($0) }) {
            return .conversation
        }

        return .other
    }
}
