import Photos
@preconcurrency import Vision

actor PhotoScanEngine {

    static let similarityThreshold: Float = 0.12
    private let imageLoader: any ImageLoader

    init(imageLoader: any ImageLoader = PHImageLoader()) {
        self.imageLoader = imageLoader
    }

    nonisolated func scan() -> AsyncStream<Result<[PhotoGroup], Error>> {
        AsyncStream { continuation in
            Task {
                do {
                    let assets = try await fetchAssets()
                    var prints: [String: VNFeaturePrintObservation] = [:]

                    let total = assets.count
                    let counter = ThreadSafeCounter()
                    let throttle = ProgressThrottle(every: 50)

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
                            if let fp { prints[id] = fp }
                            let completed = counter.increment()
                            if throttle.shouldReport(completed: completed) {
                                _ = ScanProgress(phase: "Generating embeddings", completed: completed, total: total)
                            }
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

                    var groups = cluster(assets: assets, prints: prints)
                    groups += burstGroups(from: assets)

                    var seen = Set<Set<String>>()
                    let unique = groups.filter { group in
                        let key = Set(group.assets.map { $0.localIdentifier })
                        return seen.insert(key).inserted
                    }

                    continuation.yield(.success(unique))
                } catch {
                    continuation.yield(.failure(error))
                }
                continuation.finish()
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
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func featurePrint(for asset: PHAsset) async -> VNFeaturePrintObservation? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            imageLoader.requestImage(
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

    private nonisolated func cluster(assets: [PHAsset], prints: [String: VNFeaturePrintObservation]) -> [PhotoGroup] {
        let ids = assets.map { $0.localIdentifier }
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
            if rankA < rankB {
                parent[ra] = rb
            } else if rankA > rankB {
                parent[rb] = ra
            } else {
                parent[rb] = ra
                rank[ra] = rankA + 1
            }
        }

        let printList = ids.compactMap { id -> (String, VNFeaturePrintObservation)? in
            guard let fp = prints[id] else { return nil }
            return (id, fp)
        }

        for i in 0..<printList.count {
            for j in (i+1)..<printList.count {
                var distance: Float = 0
                try? printList[i].1.computeDistance(&distance, to: printList[j].1)
                if distance < PhotoScanEngine.similarityThreshold { union(printList[i].0, printList[j].0) }
            }
        }

        var groups: [String: [PHAsset]] = [:]
        for asset in assets {
            guard prints[asset.localIdentifier] != nil else { continue }
            let root = find(asset.localIdentifier)
            groups[root, default: []].append(asset)
        }

        return groups.values.compactMap { groupAssets in
            guard groupAssets.count >= 2 else { return nil }
            let sorted = groupAssets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

            var similarity: Float = 0
            if let fp0 = prints[sorted[0].localIdentifier], let fp1 = prints[sorted[1].localIdentifier] {
                try? fp0.computeDistance(&similarity, to: fp1)
            }

            let reason: PhotoGroup.SimilarityReason
            if similarity < 0.01 {
                reason = .exactDuplicate
            } else if similarity < 0.05 {
                reason = .nearDuplicate
            } else {
                reason = .visuallySimilar
            }
            return PhotoGroup(id: UUID(), assets: sorted, similarity: similarity, reason: reason)
        }
    }

    private nonisolated func burstGroups(from assets: [PHAsset]) -> [PhotoGroup] {
        var bursts: [String: [PHAsset]] = [:]
        for asset in assets {
            if let burstId = asset.burstIdentifier { bursts[burstId, default: []].append(asset) }
        }
        return bursts.values.compactMap { groupAssets in
            guard groupAssets.count >= 2 else { return nil }
            let sorted = groupAssets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            return PhotoGroup(id: UUID(), assets: sorted, similarity: 0.0, reason: .burstShot)
        }
    }
}

enum ScanError: Error {
    case permissionDenied
}
