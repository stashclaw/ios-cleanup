import Photos
import AVFoundation
import CoreImage
@preconcurrency import Vision

// VNFeaturePrintObservation is immutable after creation — safe to send across concurrency domains.
// @retroactive silences the "future conformance conflict" diagnostic.
// Already declared in SimilarityEngine.swift; guard against redeclaration with a typealias check.

enum VideoDuplicateEvent: Sendable {
    case progress(completed: Int, total: Int)
    case groupsFound([VideoGroup])
}

actor VideoDuplicateEngine {

    // Distance < 0.35 across averaged keyframe feature prints → near-duplicate
    private static let similarityThreshold: Float = 0.35
    // Hamming distance ≤ 3 on first-frame dHash → exact duplicate
    private static let exactDuplicateHammingThreshold = 3
    // Max concurrent video processing tasks (videos are large; limit memory pressure)
    private static let maxInFlight = 4
    // Emit progress every N videos
    private static let progressInterval = 5

    nonisolated func scan() -> AsyncThrowingStream<VideoDuplicateEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await fetchVideoAssets()
                    guard !Task.isCancelled else { continuation.finish(); return }

                    let total = assets.count
                    var completed = 0

                    // For each asset: array of VNFeaturePrintObservation (1 or 3 keyframes)
                    // and the dHash of the first frame.
                    var fingerprints: [String: [VNFeaturePrintObservation]] = [:]
                    var firstFrameHashes: [String: UInt64] = [:]
                    var fileSizes: [String: Int64] = [:]

                    // Pre-compute file sizes from PHAssetResource metadata (fast, no download).
                    for asset in assets {
                        fileSizes[asset.localIdentifier] = Self.fileSize(for: asset)
                    }

                    // Sliding-window TaskGroup — max 4 in-flight (video frames are memory-heavy).
                    await withTaskGroup(of: (String, [VNFeaturePrintObservation]?, UInt64?).self) { group in
                        var nextIndex = 0
                        var inFlight = 0

                        while inFlight < Self.maxInFlight, nextIndex < assets.count {
                            let asset = assets[nextIndex]; nextIndex += 1
                            group.addTask { await self.processVideo(asset: asset) }
                            inFlight += 1
                        }

                        for await (id, prints, hash) in group {
                            guard !Task.isCancelled else { group.cancelAll(); return }

                            if let prints, !prints.isEmpty {
                                fingerprints[id] = prints
                            }
                            if let hash {
                                firstFrameHashes[id] = hash
                            }

                            completed += 1
                            if completed % Self.progressInterval == 0 || completed == total {
                                continuation.yield(.progress(completed: completed, total: total))
                            }

                            if nextIndex < assets.count {
                                let asset = assets[nextIndex]; nextIndex += 1
                                group.addTask { await self.processVideo(asset: asset) }
                            }
                        }
                    }

                    guard !Task.isCancelled else { continuation.finish(); return }

                    let groups = cluster(
                        assets: assets,
                        fingerprints: fingerprints,
                        firstFrameHashes: firstFrameHashes,
                        fileSizes: fileSizes
                    )

                    continuation.yield(.groupsFound(groups))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Asset Fetch

    private func fetchVideoAssets() async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.permissionDenied
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    // MARK: - Per-Asset Processing

    /// Returns (localIdentifier, feature prints for 1-3 keyframes, dHash of first frame).
    /// Returns nil prints/hash if the AVAsset cannot be loaded or frame extraction fails.
    private nonisolated func processVideo(asset: PHAsset) async -> (String, [VNFeaturePrintObservation]?, UInt64?) {
        let id = asset.localIdentifier

        // Request AVAsset via continuation.
        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat

            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }

        guard let avAsset else { return (id, nil, nil) }

        // Extract keyframes.
        let frames = await extractKeyframes(from: avAsset, asset: asset)
        guard !frames.isEmpty else { return (id, nil, nil) }

        // dHash of first frame for exact-duplicate detection.
        let hash = Self.computeDHash(from: frames[0])

        // Feature prints for all extracted frames.
        var prints: [VNFeaturePrintObservation] = []
        for frame in frames {
            autoreleasepool {
                let request = VNGenerateImageFeaturePrintRequest()
                try? VNImageRequestHandler(cgImage: frame, options: [:]).perform([request])
                if let fp = request.results?.first as? VNFeaturePrintObservation {
                    prints.append(fp)
                }
            }
        }

        return (id, prints.isEmpty ? nil : prints, hash)
    }

    /// Extracts 1 or 3 keyframes from an AVAsset.
    /// - Short videos (< 5 s): 1 frame at midpoint.
    /// - Longer videos: 3 frames at 10%, 50%, 90% of duration.
    private nonisolated func extractKeyframes(from avAsset: AVAsset, asset: PHAsset) async -> [CGImage] {
        let duration: CMTime
        do {
            duration = try await avAsset.load(.duration)
        } catch {
            return []
        }

        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds > 0, !durationSeconds.isNaN else { return [] }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 500, height: 500)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 1, preferredTimescale: 600)

        let fractions: [Double] = durationSeconds < 5.0
            ? [0.5]
            : [0.10, 0.50, 0.90]

        var frames: [CGImage] = []
        for fraction in fractions {
            let seconds = durationSeconds * fraction
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            do {
                let image = try generator.copyCGImage(at: time, actualTime: nil)
                frames.append(image)
            } catch {
                // Frame extraction failed at this timestamp — skip and continue.
            }
        }
        return frames
    }

    // MARK: - dHash

    private static func computeDHash(from cgImage: CGImage) -> UInt64? {
        let width = 9, height = 8
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        var hash: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                if pixels[row * width + col] < pixels[row * width + col + 1] {
                    hash |= (1 << UInt64(row * 8 + col))
                }
            }
        }
        return hash
    }

    private static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - File size helper

    private static func fileSize(for asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first(where: { $0.type == .video }) ?? resources.first
        return primary.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
    }

    // MARK: - Clustering

    private nonisolated func cluster(
        assets: [PHAsset],
        fingerprints: [String: [VNFeaturePrintObservation]],
        firstFrameHashes: [String: UInt64],
        fileSizes: [String: Int64]
    ) -> [VideoGroup] {

        // Only cluster assets that have fingerprints.
        let processedAssets = assets.filter { fingerprints[$0.localIdentifier] != nil }
        guard processedAssets.count >= 2 else { return [] }

        let ids = processedAssets.map(\.localIdentifier)

        // Union-Find data structure.
        var parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        var rank   = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        var groupReason: [String: VideoGroupReason] = [:]  // root id → best reason

        func find(_ id: String) -> String {
            if parent[id] != id { parent[id] = find(parent[id]!) }
            return parent[id]!
        }

        func union(_ a: String, _ b: String, reason: VideoGroupReason) {
            let ra = find(a), rb = find(b)
            guard ra != rb else {
                // Already in same group — upgrade reason if exact is better.
                if case .exactDuplicate = reason {
                    groupReason[ra] = .exactDuplicate
                }
                return
            }
            let rankA = rank[ra, default: 0], rankB = rank[rb, default: 0]
            let newRoot: String
            if rankA < rankB { parent[ra] = rb; newRoot = rb }
            else if rankA > rankB { parent[rb] = ra; newRoot = ra }
            else { parent[rb] = ra; rank[ra] = rankA + 1; newRoot = ra }

            // Propagate the highest-priority reason to the new root.
            let existingReason = groupReason[newRoot]
            if case .exactDuplicate = reason {
                groupReason[newRoot] = .exactDuplicate
            } else if existingReason == nil {
                groupReason[newRoot] = .nearDuplicate
            }
        }

        // Step 1: Exact duplicate detection via first-frame dHash.
        let hashedAssets = processedAssets.filter { firstFrameHashes[$0.localIdentifier] != nil }
        for i in 0..<hashedAssets.count {
            for j in (i + 1)..<hashedAssets.count {
                let idA = hashedAssets[i].localIdentifier
                let idB = hashedAssets[j].localIdentifier
                guard let hashA = firstFrameHashes[idA],
                      let hashB = firstFrameHashes[idB] else { continue }
                if Self.hammingDistance(hashA, hashB) <= Self.exactDuplicateHammingThreshold {
                    union(idA, idB, reason: .exactDuplicate)
                }
            }
        }

        // Step 2: Near-duplicate detection via average keyframe feature print distance.
        for i in 0..<processedAssets.count {
            for j in (i + 1)..<processedAssets.count {
                let idA = processedAssets[i].localIdentifier
                let idB = processedAssets[j].localIdentifier
                // Skip pairs already grouped as exact duplicates.
                if find(idA) == find(idB) {
                    if case .exactDuplicate = groupReason[find(idA)] { continue }
                }
                guard let printsA = fingerprints[idA],
                      let printsB = fingerprints[idB] else { continue }

                let avgDist = averageDistance(printsA, printsB)
                if let dist = avgDist, dist < Self.similarityThreshold {
                    union(idA, idB, reason: .nearDuplicate)
                }
            }
        }

        // Collect groups from union-find roots.
        var groups: [String: [PHAsset]] = [:]
        for asset in processedAssets {
            let root = find(asset.localIdentifier)
            groups[root, default: []].append(asset)
        }

        // Build VideoGroup objects.
        var result: [VideoGroup] = []
        for (root, groupAssets) in groups {
            guard groupAssets.count >= 2 else { continue }
            let reason = groupReason[root] ?? .nearDuplicate

            // Sort: largest file first (keep candidate), then most recent on tie.
            let sorted = groupAssets.sorted { a, b in
                let sizeA = fileSizes[a.localIdentifier] ?? 0
                let sizeB = fileSizes[b.localIdentifier] ?? 0
                if sizeA != sizeB { return sizeA > sizeB }
                return (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
            }

            let total = sorted.reduce(Int64(0)) { $0 + (fileSizes[$1.localIdentifier] ?? 0) }
            result.append(VideoGroup(id: UUID(), assets: sorted, totalBytes: total, reason: reason))
        }

        // Show most recently captured groups first.
        return result.sorted {
            ($0.assets.compactMap(\.creationDate).max() ?? .distantPast) >
            ($1.assets.compactMap(\.creationDate).max() ?? .distantPast)
        }
    }

    /// Computes the average VNFeaturePrintObservation distance between two print arrays.
    /// Compares corresponding frames (frame 0 vs frame 0, etc.) and averages across pairs.
    private nonisolated func averageDistance(
        _ a: [VNFeaturePrintObservation],
        _ b: [VNFeaturePrintObservation]
    ) -> Float? {
        let pairCount = min(a.count, b.count)
        guard pairCount > 0 else { return nil }

        var totalDist: Float = 0
        var validPairs = 0
        for i in 0..<pairCount {
            var dist: Float = 0
            if (try? a[i].computeDistance(&dist, to: b[i])) != nil {
                totalDist += dist
                validPairs += 1
            }
        }
        guard validPairs > 0 else { return nil }
        return totalDist / Float(validPairs)
    }
}
