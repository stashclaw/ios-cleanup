import Photos
@preconcurrency import Vision

enum CleanupMode: String, Codable, Sendable {
    case speedClean
    case deepClean
}

enum CleanupResultsFreshnessState: String, Codable, Sendable {
    case live
    case lastKnown
    case stale
}

struct PhotoScanUpdate: Sendable {
    let mode: CleanupMode
    let libraryTotalCount: Int
    let scanTargetCount: Int
    let processedPhotoCount: Int
    let progressFraction: Double
    let groups: [PhotoGroup]
    let groupsFoundCount: Int
    let reviewablePhotosCount: Int
    let reclaimableBytesFoundSoFar: Int64
    let hasPartialResults: Bool
    let isComplete: Bool
}

actor PhotoScanEngine {

    static let similarityThreshold: Float = 0.16
    private let bestShotRankingService = HeuristicBestShotRankingService()
    private let similarityPolicyEngine = ConservativeSimilarityPolicyEngine()
    private let keeperRankingService: KeeperRankingService = {
        let mlService = MLKeeperRankingService.shared
        if mlService.isAvailable {
            return MLEnhancedKeeperRankingService()
        }
        return ConservativeKeeperRankingService()
    }()
    private let preferenceAdjustmentService = PreferenceAdjustedRecommendationService()
    private let mlBridge = PhotoMLBridge.shared

    nonisolated func scan(mode: CleanupMode) -> AsyncThrowingStream<PhotoScanUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task(priority: .utility) {
                do {
                    let assets = try await fetchAssets()
                    let targetAssets = prioritizedAssets(from: assets, mode: mode)
                    let preferenceProfile = await PhotoPreferenceProfileStore.shared.snapshot()
                    let targetCount = targetAssets.count
                    let total = assets.count
                    var latestGroups: [PhotoGroup] = []
                    var latestReviewablePhotosCount = 0
                    var latestReclaimableBytes: Int64 = 0

                    if targetAssets.isEmpty {
                        continuation.yield(
                            PhotoScanUpdate(
                                mode: mode,
                                libraryTotalCount: total,
                                scanTargetCount: targetCount,
                                processedPhotoCount: 0,
                                progressFraction: 1,
                                groups: [],
                                groupsFoundCount: 0,
                                reviewablePhotosCount: 0,
                                reclaimableBytesFoundSoFar: 0,
                                hasPartialResults: false,
                                isComplete: true
                            )
                        )
                        continuation.finish()
                        return
                    }

                    var prints: [String: VNFeaturePrintObservation] = [:]
                    var processed = 0
                    let batchSize = mode == .speedClean ? 8 : 12
                    let refreshStride = max(batchSize * 2, 8)

                    while processed < targetCount {
                        try Task.checkCancellation()
                        let batch = Array(targetAssets[processed..<min(processed + batchSize, targetCount)])
                        await withTaskGroup(of: (String, FeaturePrintValue).self) { group in
                            for asset in batch {
                                group.addTask {
                                    let fp = await self.featurePrint(for: asset)
                                    return (asset.localIdentifier, fp)
                                }
                            }

                            for await (id, fp) in group {
                                if let observation = fp.observation {
                                    prints[id] = observation
                                }
                                processed += 1
                            }
                        }

                        // Persist features + embeddings to ML store (non-blocking)
                        let batchAssets = batch
                        let capturedPrints = prints
                        Task.detached(priority: .background) { [mlBridge] in
                            await mlBridge.persistFeatures(for: batchAssets, prints: capturedPrints)
                        }

                        if processed == targetCount || processed % refreshStride == 0 {
                            let processedAssets = Array(targetAssets.prefix(processed))
                            latestGroups = await self.enrichedGroups(
                                groups: self.uniqueGroups(
                                    groups: self.cluster(assets: processedAssets, prints: prints)
                                        + self.burstGroups(from: processedAssets)
                                        + self.sessionGroups(from: processedAssets, mode: mode)
                                ),
                                preferenceProfile: preferenceProfile
                            )
                            latestReviewablePhotosCount = latestGroups.reduce(0) { $0 + max($1.assets.count - 1, 0) }
                            latestReclaimableBytes = latestGroups.reduce(into: Int64(0)) { acc, group in
                                acc += group.reclaimableBytes
                            }
                        }

                        continuation.yield(
                            PhotoScanUpdate(
                                mode: mode,
                                libraryTotalCount: total,
                                scanTargetCount: targetCount,
                                processedPhotoCount: processed,
                                progressFraction: Double(processed) / Double(targetCount),
                                groups: latestGroups,
                                groupsFoundCount: latestGroups.count,
                                reviewablePhotosCount: latestReviewablePhotosCount,
                                reclaimableBytesFoundSoFar: latestReclaimableBytes,
                                hasPartialResults: processed < targetCount && !latestGroups.isEmpty,
                                isComplete: processed >= targetCount
                            )
                        )

                        await Task.yield()
                    }

                    let finalGroups: [PhotoGroup]
                    let reviewablePhotos: Int
                    let reclaimableBytes: Int64
                    if processed == targetCount {
                        finalGroups = latestGroups
                        reviewablePhotos = latestReviewablePhotosCount
                        reclaimableBytes = latestReclaimableBytes
                    } else {
                        finalGroups = await self.enrichedGroups(
                            groups: self.uniqueGroups(
                                groups: self.cluster(assets: targetAssets, prints: prints)
                                    + self.burstGroups(from: targetAssets)
                                    + self.sessionGroups(from: targetAssets, mode: mode)
                            ),
                            preferenceProfile: preferenceProfile
                        )
                        reviewablePhotos = finalGroups.reduce(0) { $0 + max($1.assets.count - 1, 0) }
                        reclaimableBytes = finalGroups.reduce(into: Int64(0)) { acc, group in
                            acc += group.reclaimableBytes
                        }
                    }

                    continuation.yield(
                        PhotoScanUpdate(
                            mode: mode,
                            libraryTotalCount: total,
                            scanTargetCount: targetCount,
                            processedPhotoCount: targetCount,
                            progressFraction: 1,
                            groups: finalGroups,
                            groupsFoundCount: finalGroups.count,
                            reviewablePhotosCount: reviewablePhotos,
                            reclaimableBytesFoundSoFar: reclaimableBytes,
                            hasPartialResults: !finalGroups.isEmpty,
                            isComplete: true
                        )
                    )
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
        let screenshotBit = PHAssetMediaSubtype.photoScreenshot.rawValue
        let hdrBit = PHAssetMediaSubtype.photoHDR.rawValue
        options.predicate = NSPredicate(
            format: "(mediaSubtype & %d) == 0 AND (mediaSubtype & %d) == 0",
            screenshotBit, hdrBit
        )

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    private func featurePrint(for asset: PHAsset) async -> FeaturePrintValue {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.version = .current
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 224, height: 224),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // .fastFormat can deliver a degraded image first, then the final.
                // Only resume on the final delivery to avoid resuming the continuation twice.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                guard let cgImage = image?.cgImage else {
                    continuation.resume(returning: FeaturePrintValue(observation: nil))
                    return
                }
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                let request = VNGenerateImageFeaturePrintRequest()
                do {
                    try handler.perform([request])
                    let observation = request.results?.first as? VNFeaturePrintObservation
                    continuation.resume(returning: FeaturePrintValue(observation: observation))
                } catch {
                    continuation.resume(returning: FeaturePrintValue(observation: nil))
                }
            }
        }
    }

    private nonisolated func prioritizedAssets(from assets: [PHAsset], mode: CleanupMode) -> [PHAsset] {
        let sortedByPriority: [PHAsset] = assets.sorted { lhs, rhs in
            let lhsScore = assetPriority(lhs)
            let rhsScore = assetPriority(rhs)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return (lhs.creationDate ?? .distantPast) > (rhs.creationDate ?? .distantPast)
        }

        switch mode {
        case .speedClean:
            let limit = min(assets.count, min(500, max(80, assets.count / 5)))
            let chronological = assets.sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
            // Photos with a temporal neighbour within 30 minutes are the most likely
            // to have duplicates (same session, same event). 5 minutes was too tight
            // and missed most real-world duplicate sessions.
            // Within the cluster budget, sort by most-recent first so the freshest
            // potential duplicates (likely still in user's short-term memory) are
            // always included before older clusters get the slots.
            let clusterWindow: TimeInterval = 30 * 60
            var inCluster: [PHAsset] = []
            var isolated: [PHAsset] = []
            for (i, asset) in chronological.enumerated() {
                let date = asset.creationDate ?? .distantPast
                let prevClose = i > 0 &&
                    abs(date.timeIntervalSince(chronological[i - 1].creationDate ?? .distantPast)) < clusterWindow
                let nextClose = i < chronological.count - 1 &&
                    abs(date.timeIntervalSince(chronological[i + 1].creationDate ?? .distantPast)) < clusterWindow
                if prevClose || nextClose { inCluster.append(asset) } else { isolated.append(asset) }
            }
            // Most-recent clusters first so recent duplicates always land in the scan window.
            let recentCluster = inCluster.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            var result = Array(recentCluster.prefix(limit))
            if result.count < limit {
                let needed = limit - result.count
                let seen = Set(result.map(\.localIdentifier))
                let topIsolated = isolated
                    .filter { !seen.contains($0.localIdentifier) }
                    .sorted { assetPriority($0) > assetPriority($1) }
                    .prefix(needed)
                result.append(contentsOf: topIsolated)
            }
            return result.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .deepClean:
            return sortedByPriority.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }
    }

    private nonisolated func assetPriority(_ asset: PHAsset) -> Int {
        var score = 0
        if asset.mediaSubtypes.contains(.photoScreenshot) { score += 100 }
        if asset.burstIdentifier != nil { score += 80 }
        let pixels = asset.pixelWidth * asset.pixelHeight
        if pixels >= 12_000_000 { score += 40 }
        if pixels >= 8_000_000 { score += 20 }
        if let date = asset.creationDate, date > Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast {
            score += 10
        }
        return score
    }

    private nonisolated func cluster(assets: [PHAsset], prints: [String: VNFeaturePrintObservation]) -> [PhotoGroup] {
        let orderedAssets = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        let ids = orderedAssets.map { $0.localIdentifier }
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

        let assetByID = Dictionary(uniqueKeysWithValues: orderedAssets.map { ($0.localIdentifier, $0) })
        let dateByID = Dictionary(uniqueKeysWithValues: orderedAssets.compactMap { asset -> (String, Date)? in
            guard let date = asset.creationDate else { return nil }
            return (asset.localIdentifier, date)
        })
        let printList = ids.compactMap { id -> (String, VNFeaturePrintObservation)? in
            guard let fp = prints[id] else { return nil }
            return (id, fp)
        }
        let maxComparisonWindow = SimilarityThresholds.extendedSessionWindowSeconds

        for i in 0..<printList.count {
            for j in (i+1)..<printList.count {
                if let lhsDate = dateByID[printList[i].0],
                   let rhsDate = dateByID[printList[j].0] {
                    let delta = abs(lhsDate.timeIntervalSince(rhsDate))
                    if delta > maxComparisonWindow {
                        break
                    }
                }
                var distance: Float = 0
                try? printList[i].1.computeDistance(&distance, to: printList[j].1)
                guard
                    let lhs = assetByID[printList[i].0],
                    let rhs = assetByID[printList[j].0]
                else { continue }

                if distance < similarityThreshold(lhs: lhs, rhs: rhs) {
                    union(printList[i].0, printList[j].0)
                }
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

    private nonisolated func uniqueGroups(groups: [PhotoGroup]) -> [PhotoGroup] {
        var seen = Set<Set<String>>()
        return groups.filter { group in
            let key = Set(group.assets.map { $0.localIdentifier })
            return seen.insert(key).inserted
        }
    }

    private nonisolated func similarityThreshold(lhs: PHAsset, rhs: PHAsset) -> Float {
        var threshold = PhotoScanEngine.similarityThreshold

        if lhs.burstIdentifier != nil, lhs.burstIdentifier == rhs.burstIdentifier {
            threshold += 0.12
        }

        let lhsScreenshot = lhs.mediaSubtypes.contains(.photoScreenshot)
        let rhsScreenshot = rhs.mediaSubtypes.contains(.photoScreenshot)
        if lhsScreenshot || rhsScreenshot {
            threshold += 0.08
        }

        if let lhsDate = lhs.creationDate, let rhsDate = rhs.creationDate {
            let delta = abs(lhsDate.timeIntervalSince(rhsDate))
            if delta < 3 * 60 {
                threshold += 0.10
            } else if delta < 15 * 60 {
                threshold += 0.08
            } else if delta < 60 * 60 {
                threshold += 0.04
            }
        }

        if lhs.pixelWidth == rhs.pixelWidth, lhs.pixelHeight == rhs.pixelHeight {
            threshold += 0.05
        }

        return min(threshold, 0.36)
    }

    private nonisolated func sessionGroups(from assets: [PHAsset], mode: CleanupMode) -> [PhotoGroup] {
        let chronological = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        guard !chronological.isEmpty else { return [] }

        let maxGap: TimeInterval = mode == .speedClean ? 4 * 60 : 12 * 60
        var runs: [[PHAsset]] = []
        var currentRun: [PHAsset] = []

        func flushCurrentRun() {
            guard currentRun.count >= 3 else {
                currentRun = []
                return
            }
            runs.append(currentRun)
            currentRun = []
        }

        for asset in chronological {
            guard let last = currentRun.last,
                  let lastDate = last.creationDate,
                  let currentDate = asset.creationDate else {
                if !currentRun.isEmpty {
                    flushCurrentRun()
                }
                currentRun = [asset]
                continue
            }

            if abs(currentDate.timeIntervalSince(lastDate)) <= maxGap {
                currentRun.append(asset)
            } else {
                flushCurrentRun()
                currentRun = [asset]
            }
        }
        flushCurrentRun()

        var groups: [PhotoGroup] = []
        for run in runs {
            if run.count <= 5 {
                groups.append(makeSessionGroup(from: run))
                continue
            }

            let windowSize = 5
            let strideAmount = 2
            let upperBound = max(run.count - windowSize, 0)
            for start in stride(from: 0, through: upperBound, by: strideAmount) {
                let end = min(start + windowSize, run.count)
                let window = Array(run[start..<end])
                guard window.count >= 3 else { continue }
                groups.append(makeSessionGroup(from: window))
            }
        }
        return groups
    }

    private nonisolated func makeSessionGroup(from assets: [PHAsset]) -> PhotoGroup {
        let sorted = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        let reason: PhotoGroup.SimilarityReason
        if sorted.contains(where: { $0.burstIdentifier != nil }) {
            reason = .burstShot
        } else if sorted.contains(where: { $0.mediaSubtypes.contains(.photoScreenshot) }) {
            reason = .nearDuplicate
        } else {
            reason = .visuallySimilar
        }

        let similarity: Float = {
            if reason == .burstShot { return 0.04 }
            if sorted.contains(where: { $0.mediaSubtypes.contains(.photoScreenshot) }) { return 0.08 }
            return 0.12
        }()

        return PhotoGroup(
            assets: sorted,
            similarity: similarity,
            reason: reason
        )
    }

    private func enrichedGroups(groups: [PhotoGroup], preferenceProfile: PhotoPreferenceProfile) async -> [PhotoGroup] {
        var enriched: [PhotoGroup] = []
        enriched.reserveCapacity(groups.count)
        for group in groups {
            let classification = similarityPolicyEngine.classifyGroup(group)
            guard classification.bucket != .notSimilar else { continue }

            let clusterInput = group.similarityClusterInput(baseFeatureDistance: Double(group.similarity))
            let keeperResult = keeperRankingService.rankKeeper(in: clusterInput)
            let ranked = await bestShotRankingService.rank(
                assets: group.assets,
                groupType: group.groupType
            )
            let bestCandidate = ranked.first(where: \.isBestShot)
            let keeperAssetID = classification.keeperAssetID ?? bestCandidate?.photoId
            let containsScreenshot = group.assets.contains { $0.mediaSubtypes.contains(.photoScreenshot) }
            let containsBurst = group.assets.contains { $0.burstIdentifier != nil }
            let containsEdited = group.assets.contains {
                guard let creationDate = $0.creationDate, let modificationDate = $0.modificationDate else { return false }
                return abs(modificationDate.timeIntervalSince(creationDate)) > 1
            }
            let containsFavorite = group.assets.contains { $0.isFavorite }

            let adjustment = preferenceAdjustmentService.adjust(
                .init(
                    bucket: classification.bucket,
                    groupType: classification.bucket.photoGroupReason?.defaultGroupType ?? group.groupType,
                    confidence: classification.confidence.photoGroupConfidence,
                    suggestedAction: classification.action.photoGroupAction,
                    keeperRankingResult: keeperResult,
                    preferenceProfile: preferenceProfile,
                    containsScreenshot: containsScreenshot,
                    containsBurst: containsBurst,
                    containsEdited: containsEdited,
                    containsFavorite: containsFavorite,
                    assetCount: group.assets.count
                )
            )

            let finalAction = adjustment.adjustedSuggestedAction
            let finalConfidence = adjustment.adjustedConfidence
            let finalDeleteCandidateIDs = finalAction == .keepBestTrashRest ? classification.deleteCandidateIDs : []
            let reasons = uniqueStrings(classification.reasons + adjustment.reasons + (bestCandidate?.bestShotReasons ?? []))
            enriched.append(
                PhotoGroup(
                    id: group.id,
                    assets: group.assets,
                    similarity: Float(classification.scoreBreakdown.similarityScore),
                    reason: classification.bucket.photoGroupReason ?? group.reason,
                    groupType: classification.bucket.photoGroupReason?.defaultGroupType ?? group.groupType,
                    groupConfidence: finalConfidence,
                    reviewState: group.reviewState,
                    recommendedAction: finalAction,
                    keeperAssetID: keeperAssetID,
                    deleteCandidateIDs: finalDeleteCandidateIDs,
                    bestShotPhotoId: keeperAssetID,
                    groupReasonsSummary: reasons.isEmpty ? group.groupReasonsSummary : reasons,
                    blockerFlags: classification.blockerFlags,
                    scoreBreakdown: classification.scoreBreakdown,
                    preferenceQueuePriority: adjustment.queuePriorityDelta,
                    preferenceAdjustmentReasons: adjustment.reasons,
                    captureDateRange: group.captureDateRange,
                    candidates: ranked.isEmpty ? group.candidates : ranked,
                    reclaimableBytes: estimatedReclaimableBytes(for: group.assets, deleteCandidateIDs: finalDeleteCandidateIDs)
                )
            )
        }
        return enriched
    }

    private nonisolated func estimatedReclaimableBytes(for assets: [PHAsset], deleteCandidateIDs: [String]) -> Int64 {
        guard !deleteCandidateIDs.isEmpty else { return 0 }
        let deleteIDSet = Set(deleteCandidateIDs)
        return assets.reduce(into: Int64(0)) { acc, asset in
            guard deleteIDSet.contains(asset.localIdentifier) else { return }
            acc += asset.estimatedFileSize
        }
    }

    private nonisolated func uniqueStrings(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }

    // MARK: - Perceptual hash fast-lane (8×8 pixel average hash)
    // Used to catch exact/near-exact duplicates before the Vision pipeline.

    func perceptualHash(for asset: PHAsset) async -> UInt64? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 8, height: 8),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard let cgImage = image?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                var bits: UInt64 = 0
                let colorSpace = CGColorSpaceCreateDeviceGray()
                var pixels = [UInt8](repeating: 0, count: 64)
                guard let ctx = CGContext(
                    data: &pixels, width: 8, height: 8,
                    bitsPerComponent: 8, bytesPerRow: 8,
                    space: colorSpace, bitmapInfo: 0
                ) else {
                    continuation.resume(returning: nil)
                    return
                }
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
                let avg = UInt8(pixels.map(Int.init).reduce(0, +) / 64)
                for (i, p) in pixels.enumerated() where p >= avg {
                    bits |= (1 << i)
                }
                continuation.resume(returning: bits)
            }
        }
    }
}

enum ScanError: Error {
    case permissionDenied
}

private struct FeaturePrintValue: @unchecked Sendable {
    let observation: VNFeaturePrintObservation?
}
