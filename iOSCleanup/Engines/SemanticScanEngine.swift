import Photos
import UIKit
@preconcurrency import Vision

enum SemanticScanEvent: Sendable {
    case progress(completed: Int, total: Int)
    case resultsFound([SemanticGroup])
}

actor SemanticScanEngine {

    private static let confidenceThreshold: Float = 0.4
    private static let maxInFlight: Int = 4
    private static let progressInterval: Int = 40

    nonisolated func scan() -> AsyncThrowingStream<SemanticScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await self.fetchAssets()
                    let total = assets.count

                    // Accumulate results: category → [PHAsset]
                    var buckets: [SemanticCategory: [PHAsset]] = [:]
                    for cat in SemanticCategory.allCases { buckets[cat] = [] }

                    var completed = 0

                    await withTaskGroup(of: (PHAsset, SemanticCategory?).self) { group in
                        var nextIndex = 0
                        var inFlight = 0

                        // Prime the pump
                        while inFlight < Self.maxInFlight, nextIndex < assets.count {
                            let a = assets[nextIndex]; nextIndex += 1
                            group.addTask { await self.classify(asset: a) }
                            inFlight += 1
                        }

                        for await (asset, category) in group {
                            guard !Task.isCancelled else { group.cancelAll(); return }

                            if let category {
                                buckets[category, default: []].append(asset)
                            }

                            completed += 1
                            if completed % Self.progressInterval == 0 || completed == total {
                                continuation.yield(.progress(completed: completed, total: total))
                            }

                            if nextIndex < assets.count {
                                let a = assets[nextIndex]; nextIndex += 1
                                group.addTask { await self.classify(asset: a) }
                            }
                        }
                    }

                    // Build non-empty groups, sorted by asset count descending
                    let groups: [SemanticGroup] = SemanticCategory.allCases
                        .compactMap { cat -> SemanticGroup? in
                            let assets = buckets[cat] ?? []
                            guard !assets.isEmpty else { return nil }
                            return SemanticGroup(id: UUID(), category: cat, assets: assets)
                        }
                        .sorted { $0.assets.count > $1.assets.count }

                    continuation.yield(.resultsFound(groups))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

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

    private func classify(asset: PHAsset) async -> (PHAsset, SemanticCategory?) {
        let image = await requestThumbnail(for: asset)
        guard let cgImage = image?.cgImage else { return (asset, nil) }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return (asset, nil)
        }

        guard let observations = request.results, !observations.isEmpty else {
            return (asset, nil)
        }

        // Find the highest-confidence observation that maps to one of our categories.
        // VNClassifyImageRequest returns observations sorted by confidence descending,
        // so we scan in order and stop at the first identifier that matches a category.
        var bestCategory: SemanticCategory? = nil
        var bestConfidence: Float = Self.confidenceThreshold

        outerLoop: for observation in observations where observation.confidence >= Self.confidenceThreshold {
            let identifier = observation.identifier.lowercased()
            for category in SemanticCategory.allCases {
                for prefix in category.classifierIdentifiers {
                    if identifier.hasPrefix(prefix) || identifier.contains(prefix) {
                        if observation.confidence > bestConfidence {
                            bestConfidence = observation.confidence
                            bestCategory = category
                        }
                        // Observations are sorted by confidence; once we match the top one, done.
                        break outerLoop
                    }
                }
            }
        }

        return (asset, bestCategory)
    }

    private func requestThumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isSynchronous = false
            opts.isNetworkAccessAllowed = false
            opts.resizeMode = .fast

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 224, height: 224),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
