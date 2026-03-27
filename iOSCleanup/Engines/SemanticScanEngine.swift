import Photos
import UIKit
@preconcurrency import Vision

enum SemanticScanEvent: Sendable {
    case progress(completed: Int, total: Int)
    case resultsFound([SemanticGroup])
}

actor SemanticScanEngine {

    private static let confidenceThreshold: Float = 0.4
    private static let maxInFlight = min(ProcessInfo.processInfo.activeProcessorCount, 8)
    private static let progressInterval: Int = 40

    nonisolated func scan() -> AsyncThrowingStream<SemanticScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await self.fetchAssets()
                    let total = assets.count

                    // --- SQLite cache: load fresh semantic classifications ---
                    var modDates: [String: Date] = [:]
                    modDates.reserveCapacity(assets.count)
                    for a in assets { modDates[a.localIdentifier] = a.modificationDate }

                    let cached = await AnalysisCacheStore.shared.fetchFreshAnalyses(
                        for: assets.map(\.localIdentifier),
                        currentModDates: modDates
                    )

                    // Accumulate results: category → [PHAsset]
                    var buckets: [SemanticCategory: [PHAsset]] = [:]
                    for cat in SemanticCategory.allCases { buckets[cat] = [] }

                    var uncachedAssets: [PHAsset] = []

                    for a in assets {
                        if let hit = cached[a.localIdentifier], let catStr = hit.semanticCategory,
                           let cat = SemanticCategory(rawValue: catStr) {
                            buckets[cat, default: []].append(a)
                        } else {
                            uncachedAssets.append(a)
                        }
                    }

                    let cachedCount = total - uncachedAssets.count
                    if cachedCount > 0 {
                        continuation.yield(.progress(completed: cachedCount, total: total))
                    }

                    let counter = ThreadSafeCounter()
                    var newResults: [(identifier: String, modDate: Date, category: String)] = []

                    await withTaskGroup(of: (PHAsset, SemanticCategory?).self) { group in
                        var nextIndex = 0
                        var inFlight = 0

                        // Prime the pump
                        while inFlight < Self.maxInFlight, nextIndex < uncachedAssets.count {
                            let a = uncachedAssets[nextIndex]; nextIndex += 1
                            group.addTask { await self.classify(asset: a) }
                            inFlight += 1
                        }

                        for await (asset, category) in group {
                            guard !Task.isCancelled else { group.cancelAll(); return }

                            if let category {
                                buckets[category, default: []].append(asset)
                                if let mod = modDates[asset.localIdentifier] {
                                    newResults.append((identifier: asset.localIdentifier, modDate: mod, category: category.rawValue))
                                }
                            }

                            let completed = counter.increment() + cachedCount
                            if completed % Self.progressInterval == 0 || completed == total {
                                continuation.yield(.progress(completed: completed, total: total))
                                await Task.yield()
                            }

                            if nextIndex < uncachedAssets.count {
                                let a = uncachedAssets[nextIndex]; nextIndex += 1
                                group.addTask { await self.classify(asset: a) }
                            }
                        }
                    }

                    // Persist newly computed classifications to SQLite
                    if !newResults.isEmpty {
                        await AnalysisCacheStore.shared.upsertSemanticCategories(newResults)
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

        let bestCategory: SemanticCategory? = autoreleasepool {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                return nil
            }

            guard let observations = request.results, !observations.isEmpty else {
                return nil
            }

            // Find the highest-confidence observation that maps to one of our categories.
            var best: SemanticCategory? = nil
            var bestConf: Float = Self.confidenceThreshold

            for observation in observations where observation.confidence >= Self.confidenceThreshold {
                let identifier = observation.identifier.lowercased()
                for category in SemanticCategory.allCases {
                    for prefix in category.classifierIdentifiers {
                        if identifier.hasPrefix(prefix) || identifier.contains(prefix) {
                            if observation.confidence > bestConf {
                                bestConf = observation.confidence
                                best = category
                            }
                            return best
                        }
                    }
                }
            }
            return best
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
