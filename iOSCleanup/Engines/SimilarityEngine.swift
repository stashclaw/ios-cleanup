import Photos
import Vision

enum SimilarityEvent: Sendable {
    case progress(completed: Int, total: Int)
    case groupsFound([PhotoGroup])
}

actor SimilarityEngine {

    private static let similarityThreshold: Float = 0.12
    private static let bucketInterval: TimeInterval = 15 * 60

    nonisolated func scan() -> AsyncThrowingStream<SimilarityEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await fetchAssets()
                    let total = assets.count
                    var completed = 0
                    var prints: [String: VNFeaturePrintObservation] = [:]

                    await withTaskGroup(of: (String, VNFeaturePrintObservation?).self) { group in
                        var nextIndex = 0
                        var inFlight = 0

                        while inFlight < 4, nextIndex < assets.count {
                            let a = assets[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                let fp = await self.featurePrint(for: a)
                                return (a.localIdentifier, fp)
                            }
                            inFlight += 1
                        }

                        for await (id, fp) in group {
                            if let fp {
                                prints[id] = fp
                            }
                            completed += 1
                            continuation.yield(.progress(completed: completed, total: total))
                            if nextIndex < assets.count {
                                let a = assets[nextIndex]
                                nextIndex += 1
                                group.addTask {
                                    let fp = await self.featurePrint(for: a)
                                    return (a.localIdentifier, fp)
                                }
                            }
                        }
                    }

                    let groups = cluster(assets: assets, prints: prints)
                    continuation.yield(.groupsFound(groups))
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

    private func featurePrint(for asset: PHAsset) async -> VNFeaturePrintObservation? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 299, height: 299),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                guard let cgImage = image?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                let request = VNGenerateImageFeaturePrintRequest()
                do {
                    try handler.perform([request])
                    let observation = request.results?.first as? VNFeaturePrintObservation
                    continuation.resume(returning: observation)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
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
            let key = bucketKey(for: asset)
            buckets[key, default: []].append(asset)
        }

        var allGroups: [PhotoGroup] = []

        for bucketAssets in buckets.values {
            guard bucketAssets.count >= 2 else { continue }

            let ids = bucketAssets.map { $0.localIdentifier }
            var parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })

            func find(_ id: String) -> String {
                if parent[id] != id {
                    parent[id] = find(parent[id]!)
                }
                return parent[id]!
            }

            func union(_ a: String, _ b: String) {
                let ra = find(a), rb = find(b)
                if ra != rb { parent[ra] = rb }
            }

            let printList = ids.compactMap { id -> (String, VNFeaturePrintObservation)? in
                guard let fp = prints[id] else { return nil }
                return (id, fp)
            }

            for i in 0..<printList.count {
                for j in (i+1)..<printList.count {
                    var distance: Float = 0
                    try? printList[i].1.computeDistance(&distance, to: printList[j].1)
                    if distance < Self.similarityThreshold {
                        union(printList[i].0, printList[j].0)
                    }
                }
            }

            var groups: [String: [PHAsset]] = [:]
            for asset in bucketAssets {
                guard prints[asset.localIdentifier] != nil else { continue }
                let root = find(asset.localIdentifier)
                groups[root, default: []].append(asset)
            }

            for groupAssets in groups.values {
                guard groupAssets.count >= 2 else { continue }
                let sorted = groupAssets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                allGroups.append(PhotoGroup(id: UUID(), assets: sorted, similarity: 0.0, reason: .visuallySimilar))
            }
        }

        return allGroups
    }
}
