import Photos
import Vision

actor PhotoScanEngine {

    static let similarityThreshold: Float = 0.12
    private static let sessionGapSeconds: TimeInterval = 300
    private static let bucketSize = 200
    private static let bucketOverlap = 40

    private struct PrintedAssetRecord: @unchecked Sendable {
        let asset: PHAsset
        let id: String
        let fp: VNFeaturePrintObservation
    }

    private typealias PrintedAsset = PrintedAssetRecord

    private struct ComparisonPair: Hashable, Sendable {
        let lhs: String
        let rhs: String

        init(_ a: String, _ b: String) {
            if a < b {
                lhs = a
                rhs = b
            } else {
                lhs = b
                rhs = a
            }
        }
    }

    nonisolated func scan() -> AsyncStream<Result<[PhotoGroup], Error>> {
        AsyncStream { continuation in
            Task {
                do {
                    let assets = try await fetchAssets()
                    var prints: [String: VNFeaturePrintObservation] = [:]

                    // Generate feature prints with max 4 concurrent tasks
                    let total = assets.count
                    var completed = 0

                    await withTaskGroup(of: (String, VNFeaturePrintObservation?).self) { group in
                        var nextIndex = 0
                        var inFlight = 0

                        // Seed up to 4
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
                            if completed % 50 == 0 {
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

                    var groups = await clusteredFast(assets: assets, prints: prints)
                    groups += burstGroups(from: assets)

                    // De-duplicate by asset identifiers
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

    private nonisolated func clusteredFast(
        assets: [PHAsset],
        prints: [String: VNFeaturePrintObservation]
    ) async -> [PhotoGroup] {
        let ids = assets.map { $0.localIdentifier }
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

        let sessions = makeSessions(from: assets, prints: prints)

        for session in sessions where session.count >= 2 {
            let sortedSession = session.sorted { scalarKey(for: $0.fp) < scalarKey(for: $1.fp) }
            let buckets = makeBuckets(from: sortedSession)

            let pairs = await withTaskGroup(of: [ComparisonPair].self) { group in
                for bucket in buckets {
                    group.addTask {
                        guard bucket.count >= 2 else { return [] }

                        var localPairs: [ComparisonPair] = []
                        for i in 0..<(bucket.count - 1) {
                            for j in (i + 1)..<bucket.count {
                                var distance: Float = 0
                                try? bucket[i].fp.computeDistance(&distance, to: bucket[j].fp)
                                if distance < PhotoScanEngine.similarityThreshold {
                                    localPairs.append(ComparisonPair(bucket[i].id, bucket[j].id))
                                }
                            }
                        }
                        return localPairs
                    }
                }

                var collected: [ComparisonPair] = []
                for await bucketPairs in group {
                    collected.append(contentsOf: bucketPairs)
                }
                return collected
            }

            var seenPairs = Set<ComparisonPair>()
            for pair in pairs where seenPairs.insert(pair).inserted {
                union(pair.lhs, pair.rhs)
            }
        }

        // Collect groups by root
        var groups: [String: [PHAsset]] = [:]
        for asset in assets {
            guard prints[asset.localIdentifier] != nil else { continue }
            let root = find(asset.localIdentifier)
            groups[root, default: []].append(asset)
        }

        return groups.values.compactMap { groupAssets in
            guard groupAssets.count >= 2 else { return nil }
            let sorted = groupAssets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

            // Calculate representative similarity (first pair)
            var similarity: Float = 0
            if let fp0 = prints[sorted[0].localIdentifier],
               let fp1 = prints[sorted[1].localIdentifier] {
                try? fp0.computeDistance(&similarity, to: fp1)
            }

            let reason: PhotoGroup.SimilarityReason = similarity < 0.05 ? .nearDuplicate : .visuallySimilar
            return PhotoGroup(id: UUID(), assets: sorted, similarity: similarity, reason: reason)
        }
    }

    private nonisolated func makeSessions(
        from assets: [PHAsset],
        prints: [String: VNFeaturePrintObservation]
    ) -> [[PrintedAsset]] {
        var sessions: [[PrintedAsset]] = []
        var currentSession: [PrintedAsset] = []
        var previousDate: Date?

        for asset in assets {
            guard let fp = prints[asset.localIdentifier] else { continue }

            let effectiveDate = asset.creationDate ?? previousDate ?? .distantPast
            if let previousDate, effectiveDate.timeIntervalSince(previousDate) > Self.sessionGapSeconds,
               !currentSession.isEmpty {
                sessions.append(currentSession)
                currentSession = []
            }

            currentSession.append(PrintedAsset(asset: asset, id: asset.localIdentifier, fp: fp))
            previousDate = effectiveDate
        }

        if !currentSession.isEmpty {
            sessions.append(currentSession)
        }

        return sessions
    }

    private nonisolated func makeBuckets(from session: [PrintedAsset]) -> [[PrintedAsset]] {
        guard session.count >= 2 else { return [] }

        if session.count <= Self.bucketSize {
            return [session]
        }

        let step = max(1, Self.bucketSize - Self.bucketOverlap)
        var buckets: [[PrintedAsset]] = []
        var start = 0

        while start < session.count {
            let end = min(session.count, start + Self.bucketSize)
            buckets.append(Array(session[start..<end]))
            if end == session.count {
                break
            }
            start += step
        }

        return buckets
    }

    private nonisolated func scalarKey(for observation: VNFeaturePrintObservation) -> Float {
        let data = observation.data
        guard data.count >= MemoryLayout<Float32>.size else { return 0 }

        return data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: Float32.self)
        }
    }

    private nonisolated func burstGroups(from assets: [PHAsset]) -> [PhotoGroup] {
        var bursts: [String: [PHAsset]] = [:]
        for asset in assets {
            if let burstId = asset.burstIdentifier {
                bursts[burstId, default: []].append(asset)
            }
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
