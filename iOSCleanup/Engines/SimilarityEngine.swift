import Photos
@preconcurrency import Vision

// VNFeaturePrintObservation is immutable after creation — safe to send across concurrency domains.
// @retroactive silences the "future conformance conflict" diagnostic.
extension VNFeaturePrintObservation: @retroactive @unchecked Sendable {}

enum SimilarityEvent: Sendable {
    case progress(completed: Int, total: Int)
    case groupsFound([PhotoGroup])
}

actor SimilarityEngine {

    // Raised from 0.12 → 0.5 to match CleanIt: catches far more visually similar photos.
    // 0.12 was too strict and missed obvious duplicates shot seconds apart.
    private static let similarityThreshold: Float = 0.5
    private static let bucketInterval: TimeInterval = 15 * 60
    // 224×224 is the standard ImageNet input size — more efficient than 299×299.
    private static let featurePrintSize: CGFloat = 224
    private let imageLoader: any ImageLoader

    init(imageLoader: any ImageLoader = PHImageLoader()) {
        self.imageLoader = imageLoader
    }

    nonisolated func scan(addedAfter: Date? = nil) -> AsyncThrowingStream<SimilarityEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await fetchAssets(addedAfter: addedAfter)
                    guard !Task.isCancelled else { continuation.finish(); return }

                    let total = assets.count
                    let counter = ThreadSafeCounter()
                    let throttle = ProgressThrottle(every: 15)
                    var prints: [String: VNFeaturePrintObservation] = [:]

                    await withTaskGroup(of: (String, VNFeaturePrintObservation?).self) { group in
                        var nextIndex = 0
                        var inFlight = 0

                        while inFlight < 3, nextIndex < assets.count {
                            let a = assets[nextIndex]; nextIndex += 1
                            group.addTask { await self.featurePrint(for: a) }
                            inFlight += 1
                        }

                        for await (id, fp) in group {
                            guard !Task.isCancelled else { group.cancelAll(); return }

                            if let fp { prints[id] = fp }
                            let completed = counter.increment()
                            if throttle.shouldReport(completed: completed) {
                                continuation.yield(.progress(completed: completed, total: total))
                                await Task.yield()
                            }
                            if nextIndex < assets.count {
                                let a = assets[nextIndex]; nextIndex += 1
                                group.addTask { await self.featurePrint(for: a) }
                            }
                        }
                    }

                    guard !Task.isCancelled else { continuation.finish(); return }

                    let groups = cluster(assets: assets, prints: prints)
                    continuation.yield(.groupsFound(groups))
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

    // Returns (localIdentifier, observation) so the caller can build the prints dict.
    // nonisolated: doesn't access actor state, avoids crossing the isolation boundary
    // with a non-Sendable VNFeaturePrintObservation return value.
    private nonisolated func featurePrint(for asset: PHAsset) async -> (String, VNFeaturePrintObservation?) {
        let id = asset.localIdentifier
        let observation: VNFeaturePrintObservation? = await withCheckedContinuation { continuation in
            var didResume = false

            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            imageLoader.requestImage(
                for: asset,
                targetSize: CGSize(width: Self.featurePrintSize, height: Self.featurePrintSize),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !didResume else { return }

                // Skip degraded (low-res preview) callbacks — wait for the final delivery.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelledOrError = info?[PHImageCancelledKey] != nil || info?[PHImageErrorKey] != nil
                guard !isDegraded || isCancelledOrError else { return }

                didResume = true

                guard let cgImage = image?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }

                autoreleasepool {
                    let request = VNGenerateImageFeaturePrintRequest()
                    try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                    continuation.resume(returning: request.results?.first as? VNFeaturePrintObservation)
                }
            }
        }
        return (id, observation)
    }

    private nonisolated func bucketKey(for asset: PHAsset) -> String {
        let date = asset.creationDate ?? .distantPast
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let bucketIndex = Int(date.timeIntervalSince1970 / Self.bucketInterval)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)-\(bucketIndex)"
    }

    private nonisolated func cluster(assets: [PHAsset], prints: [String: VNFeaturePrintObservation]) -> [PhotoGroup] {
        var buckets: [String: [PHAsset]] = [:]
        for asset in assets {
            guard prints[asset.localIdentifier] != nil else { continue }
            buckets[bucketKey(for: asset), default: []].append(asset)
        }

        var allGroups: [PhotoGroup] = []

        for bucketAssets in buckets.values {
            guard bucketAssets.count >= 2 else { continue }

            let ids = bucketAssets.map { $0.localIdentifier }
            var parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
            var rank   = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })

            func find(_ id: String) -> String {
                if parent[id] != id { parent[id] = find(parent[id]!) }
                return parent[id]!
            }

            func union(_ a: String, _ b: String) {
                let ra = find(a), rb = find(b)
                guard ra != rb else { return }
                let rankA = rank[ra, default: 0], rankB = rank[rb, default: 0]
                if rankA < rankB { parent[ra] = rb }
                else if rankA > rankB { parent[rb] = ra }
                else { parent[rb] = ra; rank[ra] = rankA + 1 }
            }

            let printList = ids.compactMap { id -> (String, VNFeaturePrintObservation)? in
                guard let fp = prints[id] else { return nil }
                return (id, fp)
            }

            for i in 0..<printList.count {
                for j in (i + 1)..<printList.count {
                    var distance: Float = 0
                    try? printList[i].1.computeDistance(&distance, to: printList[j].1)
                    if distance < Self.similarityThreshold { union(printList[i].0, printList[j].0) }
                }
            }

            var groups: [String: [PHAsset]] = [:]
            for asset in bucketAssets {
                guard prints[asset.localIdentifier] != nil else { continue }
                groups[find(asset.localIdentifier), default: []].append(asset)
            }

            for groupAssets in groups.values {
                guard groupAssets.count >= 2 else { continue }
                // Sort best-quality (highest resolution) first, then by date.
                let sorted = groupAssets.sorted {
                    let lPx = $0.pixelWidth * $0.pixelHeight
                    let rPx = $1.pixelWidth * $1.pixelHeight
                    if lPx != rPx { return lPx > rPx }
                    return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
                }
                allGroups.append(PhotoGroup(id: UUID(), assets: sorted, similarity: 0.0, reason: .visuallySimilar))
            }
        }

        // Show most recently captured groups first.
        return allGroups.sorted {
            ($0.assets.compactMap(\.creationDate).max() ?? .distantPast) >
            ($1.assets.compactMap(\.creationDate).max() ?? .distantPast)
        }
    }
}
