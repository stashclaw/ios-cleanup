import CoreGraphics
import Foundation
@preconcurrency import Photos
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
    /// Assets that produced a usable Vision feature print.
    let analyzedPhotoCount: Int
    /// Attempted assets that produced no usable Vision feature print.
    let unanalyzedPhotoCount: Int
    let progressFraction: Double
    let groups: [PhotoGroup]
    let screenshotAssets: [PHAsset]
    let blurryAssets: [PHAsset]
    let groupsFoundCount: Int
    let reviewablePhotosCount: Int
    let reclaimableBytesFoundSoFar: Int64
    let hasPartialResults: Bool
    let isComplete: Bool
    /// Assets analyzed for this run. Incremental callers use this to replace
    /// only affected cached groups instead of clearing the whole library result.
    var evaluatedAssetIDs: Set<String> = []
    /// Stable work set selected when this run began. Persisting it prevents an
    /// interrupted Speed Clean from expanding into a full-library resume.
    var targetAssetIDs: Set<String> = []
    /// Attempted assets whose analysis produced no usable feature print this
    /// run. Persisted so an explicit retry pass can target exactly these.
    var unanalyzedAssetIDs: Set<String> = []
    /// Batch-aligned counters for durable checkpoints. Fine-grained UI progress
    /// may be ahead of these values while a batch is still being assembled.
    var committedProcessedPhotoCount: Int?
    var committedAnalyzedPhotoCount: Int?
    var committedUnanalyzedPhotoCount: Int?

    var hasUnanalyzedPhotos: Bool {
        unanalyzedPhotoCount > 0
    }
}

protocol PhotoScanAssetProviding: Sendable {
    func fetchImageAssets() async throws -> [PHAsset]
}

struct SystemPhotoScanAssetProvider: PhotoScanAssetProviding {
    func fetchImageAssets() async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.permissionDenied
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true)
        ]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }
}

struct PhotoScanAssetAnalysis: @unchecked Sendable {
    let observation: VNFeaturePrintObservation?
    let embedding: Data?
    let perceptualHash: UInt64?
    let keeperSignals: KeeperSignals?

    static let unavailable = PhotoScanAssetAnalysis(
        observation: nil,
        embedding: nil,
        perceptualHash: nil,
        keeperSignals: nil
    )
}

typealias PhotoScanAssetAnalyzer = @Sendable (
    _ asset: PHAsset,
    _ allowNetworkAccess: Bool
) async -> PhotoScanAssetAnalysis

actor LazyOptionalMLKeeperRankingService: KeeperRankingService {
    typealias OptionalRankerFactory = @Sendable (
        any KeeperRankingService
    ) -> (any KeeperRankingService)?

    private let conservativeRanker: any KeeperRankingService
    private let optionalRankerFactory: OptionalRankerFactory
    private var optionalRanker: (any KeeperRankingService)?
    private var hasResolvedOptionalRanker = false

    init(
        conservativeRanker: any KeeperRankingService = ConservativeKeeperRankingService(),
        optionalRankerFactory: @escaping OptionalRankerFactory = { conservativeRanker in
            guard MLKeeperRankingService.shared.isAvailable else { return nil }
            return MLEnhancedKeeperRankingService(
                heuristicService: conservativeRanker
            )
        }
    ) {
        self.conservativeRanker = conservativeRanker
        self.optionalRankerFactory = optionalRankerFactory
    }

    func rankKeeper(in input: SimilarityClusterInput) async -> KeeperRankingResult {
        let ranker = resolveOptionalRanker() ?? conservativeRanker
        return await ranker.rankKeeper(in: input)
    }

    private func resolveOptionalRanker() -> (any KeeperRankingService)? {
        guard !hasResolvedOptionalRanker else { return optionalRanker }
        hasResolvedOptionalRanker = true
        optionalRanker = optionalRankerFactory(conservativeRanker)
        return optionalRanker
    }
}

actor PhotoScanEngine {
    private let pairClassifier = ConservativePairSimilarityClassifier()
    private let candidateGraph = SimilarityCandidateGraph()
    private let similarityPolicyEngine: ConservativeSimilarityPolicyEngine
    private let preferenceAdjustmentService = PreferenceAdjustedRecommendationService()
    private let mlBridge = PhotoMLBridge.shared
    private let assetProvider: any PhotoScanAssetProviding
    private let assetAnalyzer: PhotoScanAssetAnalyzer
    private var isPaused = false

    init(
        assetProvider: any PhotoScanAssetProviding = SystemPhotoScanAssetProvider(),
        assetAnalyzer: PhotoScanAssetAnalyzer? = nil
    ) {
        self.assetProvider = assetProvider
        self.assetAnalyzer = assetAnalyzer ?? { asset, allowNetworkAccess in
            await PhotoScanEngine.analyzeAsset(
                asset,
                allowNetworkAccess: allowNetworkAccess
            )
        }
        // Engine construction often happens on HomeViewModel's main actor.
        // Keep the safe ranker eager, but defer all optional ML selection/loading
        // until ranking runs asynchronously on the lazy ranker's actor.
        similarityPolicyEngine = ConservativeSimilarityPolicyEngine(
            keeperRankingService: LazyOptionalMLKeeperRankingService()
        )
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    nonisolated func scan(
        mode: CleanupMode,
        allowNetworkAccess: Bool = PhotoScanDefaults.allowNetworkAccess,
        requiredAssetIDs: Set<String>? = nil
    ) -> AsyncThrowingStream<PhotoScanUpdate, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let scanTask = Task(priority: .utility) {
                await self.performScan(
                    mode: mode,
                    allowNetworkAccess: allowNetworkAccess,
                    requiredAssetIDs: requiredAssetIDs,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in
                scanTask.cancel()
            }
        }
    }

    private func performScan(
        mode: CleanupMode,
        allowNetworkAccess: Bool,
        requiredAssetIDs: Set<String>?,
        continuation: AsyncThrowingStream<PhotoScanUpdate, Error>.Continuation
    ) async {
        do {
            isPaused = false
            let allAssets = try await assetProvider.fetchImageAssets()
            let targetAssets: [PHAsset]
            if let requiredAssetIDs {
                targetAssets = incrementalAssets(
                    from: allAssets,
                    requiredAssetIDs: requiredAssetIDs
                )
            } else {
                targetAssets = prioritizedAssets(from: allAssets, mode: mode)
            }
            let preferenceProfile = await PhotoPreferenceProfileStore.shared.snapshot()
            let totalCount = allAssets.count
            let targetCount = targetAssets.count
            let targetAssetIDs = Set(targetAssets.map(\.localIdentifier))
            var evaluatedAssetIDs = Set<String>()
            var unanalyzedAssetIDs = Set<String>()

            guard !targetAssets.isEmpty else {
                continuation.yield(
                    PhotoScanUpdate(
                        mode: mode,
                        libraryTotalCount: totalCount,
                        scanTargetCount: 0,
                        processedPhotoCount: 0,
                        analyzedPhotoCount: 0,
                        unanalyzedPhotoCount: 0,
                        progressFraction: 1,
                        groups: [],
                        screenshotAssets: [],
                        blurryAssets: [],
                        groupsFoundCount: 0,
                        reviewablePhotosCount: 0,
                        reclaimableBytesFoundSoFar: 0,
                        hasPartialResults: false,
                        isComplete: true,
                        evaluatedAssetIDs: [],
                        targetAssetIDs: [],
                        committedProcessedPhotoCount: 0,
                        committedAnalyzedPhotoCount: 0,
                        committedUnanalyzedPhotoCount: 0
                    )
                )
                await performMLRetentionAfterSuccessfulScan(
                    activeAssetIDs: Set(allAssets.map(\.localIdentifier))
                )
                continuation.finish()
                return
            }

            let targetAssetsByID = Dictionary(
                uniqueKeysWithValues: targetAssets.map { ($0.localIdentifier, $0) }
            )
            var assetsByID: [String: PHAsset] = [:]
            var descriptorsByID: [String: SimilarityAssetDescriptor] = [:]
            var featurePrintsByID: [String: VNFeaturePrintObservation] = [:]
            var keeperSignalsByID: [String: KeeperSignals] = [:]
            var pairSignals: [SimilarityPairKey: SimilaritySignals] = [:]
            var pairResults: [SimilarityPairKey: PairEligibilityResult] = [:]
            var screenshotIDsByHash: [UInt64: [String]] = [:]
            var burstIDsByIdentifier: [String: [String]] = [:]
            var orderedProcessedIDs: [String] = []
            var screenshotFeatureRetentionQueue: [String] = []
            var screenshotFeatureRetentionCursor = 0
            var cachedGroups: [PhotoScanGroupCacheKey: CachedPhotoScanGroup] = [:]

            var processedCount = 0
            var analyzedPhotoCount = 0
            var unanalyzedPhotoCount = 0
            var latestGroups: [PhotoGroup] = []
            // Screenshot membership is reliable PHAsset metadata. Publish it
            // immediately instead of waiting for Vision or an iCloud download.
            let screenshotAssets = targetAssets.filter {
                $0.mediaSubtypes.contains(.photoScreenshot)
            }
            var blurryAssets: [PHAsset] = []
            // Eight concurrent PhotoKit/Vision requests substantially improves
            // large-library throughput while remaining bounded so foreground
            // review thumbnails can still use the shared image manager.
            let batchSize = PhotoScanDefaults.analysisBatchSize
            let refreshStride = max(batchSize * 2, 8)
            var nextGroupRefreshCount = min(refreshStride, targetCount)
            let assetAnalyzer = self.assetAnalyzer

            continuation.yield(
                PhotoScanUpdate(
                    mode: mode,
                    libraryTotalCount: totalCount,
                    scanTargetCount: targetCount,
                    processedPhotoCount: 0,
                    analyzedPhotoCount: 0,
                    unanalyzedPhotoCount: 0,
                    progressFraction: 0,
                    groups: [],
                    screenshotAssets: screenshotAssets,
                    blurryAssets: [],
                    groupsFoundCount: 0,
                    reviewablePhotosCount: screenshotAssets.count,
                    reclaimableBytesFoundSoFar: 0,
                    hasPartialResults: !screenshotAssets.isEmpty,
                    isComplete: false,
                    evaluatedAssetIDs: evaluatedAssetIDs,
                    targetAssetIDs: targetAssetIDs,
                    committedProcessedPhotoCount: 0,
                    committedAnalyzedPhotoCount: 0,
                    committedUnanalyzedPhotoCount: 0
                )
            )

            while processedCount < targetCount {
                try await waitWhilePaused()
                let end = min(processedCount + batchSize, targetCount)
                let batch = Array(targetAssets[processedCount..<end])
                let workItems = batch.map(AssetWorkItem.init(asset:))
                var analyses: [AnalyzedAsset] = []
                analyses.reserveCapacity(batch.count)
                var batchAnalyzedPhotoCount = 0
                var batchUnanalyzedPhotoCount = 0

                await withTaskGroup(of: AnalyzedAsset.self) { group in
                    for workItem in workItems {
                        group.addTask {
                            let featureValue = await assetAnalyzer(
                                workItem.asset,
                                allowNetworkAccess
                            )
                            return AnalyzedAsset(
                                assetID: workItem.asset.localIdentifier,
                                featureValue: featureValue
                            )
                        }
                    }

                    for await analysis in group {
                        analyses.append(analysis)
                        if analysis.featureValue.observation == nil {
                            batchUnanalyzedPhotoCount += 1
                            unanalyzedAssetIDs.insert(analysis.assetID)
                        } else {
                            batchAnalyzedPhotoCount += 1
                        }
                        let attemptedCount = processedCount + analyses.count
                        let reviewableCount = PhotoReviewCategoryClassifier.reviewableCount(
                            groups: latestGroups,
                            screenshotAssets: screenshotAssets,
                            blurryAssets: blurryAssets
                        )
                        continuation.yield(
                            PhotoScanUpdate(
                                mode: mode,
                                libraryTotalCount: totalCount,
                                scanTargetCount: targetCount,
                                processedPhotoCount: attemptedCount,
                                analyzedPhotoCount: analyzedPhotoCount + batchAnalyzedPhotoCount,
                                unanalyzedPhotoCount: unanalyzedPhotoCount + batchUnanalyzedPhotoCount,
                                progressFraction: Double(attemptedCount) / Double(targetCount),
                                groups: latestGroups,
                                screenshotAssets: screenshotAssets,
                                blurryAssets: blurryAssets,
                                groupsFoundCount: latestGroups.count,
                                reviewablePhotosCount: reviewableCount,
                                reclaimableBytesFoundSoFar: latestGroups.totalReclaimableBytes,
                                hasPartialResults: !latestGroups.isEmpty,
                                isComplete: false,
                                evaluatedAssetIDs: evaluatedAssetIDs,
                                targetAssetIDs: targetAssetIDs,
                                unanalyzedAssetIDs: unanalyzedAssetIDs,
                                committedProcessedPhotoCount: processedCount,
                                committedAnalyzedPhotoCount: analyzedPhotoCount,
                                committedUnanalyzedPhotoCount: unanalyzedPhotoCount
                            )
                        )
                    }
                }

                analyzedPhotoCount += batchAnalyzedPhotoCount
                unanalyzedPhotoCount += batchUnanalyzedPhotoCount

                analyses.sort { lhs, rhs in
                    guard let lhsAsset = targetAssetsByID[lhs.assetID],
                          let rhsAsset = targetAssetsByID[rhs.assetID] else {
                        return lhs.assetID < rhs.assetID
                    }
                    let lhsDate = lhsAsset.creationDate ?? .distantPast
                    let rhsDate = rhsAsset.creationDate ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                    return lhs.assetID < rhs.assetID
                }

                var newPairRecords: [PairSimilarityRecord] = []
                for analysis in analyses {
                    try await waitWhilePaused()
                    guard let asset = targetAssetsByID[analysis.assetID] else { continue }

                    let descriptor = SimilaritySignalBuilder.descriptor(for: asset)
                    assetsByID[analysis.assetID] = asset
                    descriptorsByID[analysis.assetID] = descriptor
                    if let observation = analysis.featureValue.observation {
                        featurePrintsByID[analysis.assetID] = observation
                    }
                    if let keeperSignals = analysis.featureValue.keeperSignals {
                        keeperSignalsByID[analysis.assetID] = keeperSignals
                    }
                    switch PhotoReviewCategoryClassifier.classify(
                        isScreenshot: descriptor.isScreenshot,
                        sharpness: analysis.featureValue.keeperSignals?.sharpness
                    ) {
                    case .screenshot:
                        break
                    case .blurry:
                        blurryAssets.append(asset)
                    case nil:
                        break
                    }

                    let candidateIDs = comparisonCandidateIDs(
                        for: descriptor,
                        perceptualHash: analysis.featureValue.perceptualHash,
                        orderedProcessedIDs: orderedProcessedIDs,
                        descriptorsByID: descriptorsByID,
                        screenshotIDsByHash: screenshotIDsByHash,
                        burstIDsByIdentifier: burstIDsByIdentifier
                    )
                    let candidateKeys = candidateIDs.map {
                        SimilarityPairKey(descriptor.id, $0)
                    }
                    let cachedPairRecords = await mlBridge.cachedPairSimilarities(
                        for: candidateKeys
                    )

                    var evaluatedPairs: [CandidatePairEvidence] = []
                    evaluatedPairs.reserveCapacity(candidateIDs.count)
                    for candidateID in candidateIDs {
                        guard let candidateDescriptor = descriptorsByID[candidateID] else { continue }
                        let key = SimilarityPairKey(
                            descriptor.id,
                            candidateDescriptor.id
                        )
                        let distanceResolution: PhotoScanPairDistanceResolution
                        if let cachedResolution = PhotoScanPairDistanceResolver.cachedResolution(
                            key: key,
                            cachedRecords: cachedPairRecords
                        ) {
                            distanceResolution = cachedResolution
                        } else {
                            distanceResolution = PhotoScanPairDistanceResolution(
                                distance: featureDistance(
                                    lhs: featurePrintsByID[analysis.assetID],
                                    rhs: featurePrintsByID[candidateID]
                                ),
                                wasCacheHit: false
                            )
                        }
                        let distance = distanceResolution.distance
                        let signals = SimilaritySignals.make(
                            lhs: descriptor,
                            rhs: candidateDescriptor,
                            featureDistance: distance
                        )
                        let result = pairClassifier.classifyPair(
                            lhs: descriptor,
                            rhs: candidateDescriptor,
                            signals: signals
                        )

                        // Ineligible generic pairs are discarded. Burst evidence is
                        // retained so divergence can lower confidence without losing
                        // the explicit burst review unit.
                        guard result.eligible || signals.isBurstPair else { continue }
                        evaluatedPairs.append(
                            CandidatePairEvidence(
                                key: key,
                                signals: signals,
                                result: result,
                                featureDistance: distance,
                                wasCacheHit: distanceResolution.wasCacheHit
                            )
                        )
                    }

                    let retainedEdgeLimit = descriptor.burstIdentifier == nil
                        ? SimilarityThresholds.maxRetainedGenericPairEdgesPerAsset
                        : SimilarityThresholds.maxBurstAssetsPerCluster - 1
                    let retainedPairs = evaluatedPairs
                        .sorted { lhs, rhs in
                            if lhs.result.similarityScore != rhs.result.similarityScore {
                                return lhs.result.similarityScore > rhs.result.similarityScore
                            }
                            if lhs.key.lhsID != rhs.key.lhsID {
                                return lhs.key.lhsID < rhs.key.lhsID
                            }
                            return lhs.key.rhsID < rhs.key.rhsID
                        }
                        .prefix(retainedEdgeLimit)

                    for evidence in retainedPairs {
                        pairSignals[evidence.key] = evidence.signals
                        pairResults[evidence.key] = evidence.result
                        if let distance = evidence.featureDistance,
                           !evidence.wasCacheHit {
                            newPairRecords.append(
                                PairSimilarityRecord(
                                    lhsAssetID: evidence.key.lhsID,
                                    rhsAssetID: evidence.key.rhsID,
                                    featureDistance: distance,
                                    timeDeltaSeconds: evidence.signals.captureTimeDeltaSeconds,
                                    isBurstPair: evidence.signals.isBurstPair,
                                    bucket: evidence.result.provisionalBucket.rawValue,
                                    similarityScore: evidence.result.similarityScore
                                )
                            )
                        }
                    }

                    if descriptor.isScreenshot {
                        if let hash = analysis.featureValue.perceptualHash,
                           analysis.featureValue.observation != nil {
                            var hashBucket = screenshotIDsByHash[hash, default: []]
                            hashBucket.append(descriptor.id)
                            if hashBucket.count > SimilarityThresholds.maxFeatureComparisonsPerAsset {
                                hashBucket.removeFirst(
                                    hashBucket.count - SimilarityThresholds.maxFeatureComparisonsPerAsset
                                )
                            }
                            screenshotIDsByHash[hash] = hashBucket
                            screenshotFeatureRetentionQueue.append(descriptor.id)
                        } else {
                            featurePrintsByID.removeValue(forKey: descriptor.id)
                        }
                    }
                    if let burstIdentifier = descriptor.burstIdentifier {
                        burstIDsByIdentifier[burstIdentifier, default: []].append(descriptor.id)
                    }
                    orderedProcessedIDs.append(descriptor.id)
                    evaluatedAssetIDs.insert(descriptor.id)

                    if orderedProcessedIDs.count > SimilarityThresholds.maxCandidateAssetsInspected {
                        let expiredIndex = orderedProcessedIDs.count
                            - SimilarityThresholds.maxCandidateAssetsInspected
                            - 1
                        let expiredID = orderedProcessedIDs[expiredIndex]
                        if descriptorsByID[expiredID]?.isScreenshot == false {
                            featurePrintsByID.removeValue(forKey: expiredID)
                        }
                    }

                    while screenshotFeatureRetentionQueue.count - screenshotFeatureRetentionCursor
                        > SimilarityThresholds.maxRetainedScreenshotFeaturePrints
                    {
                        let expiredID = screenshotFeatureRetentionQueue[screenshotFeatureRetentionCursor]
                        screenshotFeatureRetentionCursor += 1
                        featurePrintsByID.removeValue(forKey: expiredID)
                    }
                    if screenshotFeatureRetentionCursor >= 1_000,
                       screenshotFeatureRetentionCursor * 2 >= screenshotFeatureRetentionQueue.count {
                        screenshotFeatureRetentionQueue.removeFirst(screenshotFeatureRetentionCursor)
                        screenshotFeatureRetentionCursor = 0
                    }
                }

                processedCount += analyses.count

                let embeddings = Dictionary(
                    uniqueKeysWithValues: analyses.compactMap { analysis in
                        analysis.featureValue.embedding.map { (analysis.assetID, $0) }
                    }
                )
                let featureRecords = mlBridge.makeFeatureRecords(
                    for: batch,
                    embeddings: embeddings
                )
                await mlBridge.persistFeatureRecords(featureRecords)
                await mlBridge.persistPairSimilarities(newPairRecords)

                if processedCount == targetCount || processedCount >= nextGroupRefreshCount {
                    latestGroups = await makeGroups(
                        assetsByID: assetsByID,
                        descriptorsByID: descriptorsByID,
                        keeperSignalsByID: keeperSignalsByID,
                        pairSignals: pairSignals,
                        pairResults: pairResults,
                        preferenceProfile: preferenceProfile,
                        cachedGroups: &cachedGroups
                    )
                    nextGroupRefreshCount = PhotoScanRefreshSchedule.nextThreshold(
                        after: processedCount,
                        currentThreshold: nextGroupRefreshCount,
                        targetCount: targetCount,
                        minimumStride: refreshStride
                    )
                }

                let reviewableCount = PhotoReviewCategoryClassifier.reviewableCount(
                    groups: latestGroups,
                    screenshotAssets: screenshotAssets,
                    blurryAssets: blurryAssets
                )
                let reclaimableBytes = latestGroups.totalReclaimableBytes
                let isComplete = processedCount >= targetCount
                continuation.yield(
                    PhotoScanUpdate(
                        mode: mode,
                        libraryTotalCount: totalCount,
                        scanTargetCount: targetCount,
                        processedPhotoCount: processedCount,
                        analyzedPhotoCount: analyzedPhotoCount,
                        unanalyzedPhotoCount: unanalyzedPhotoCount,
                        progressFraction: Double(processedCount) / Double(targetCount),
                        groups: latestGroups,
                        screenshotAssets: screenshotAssets,
                        blurryAssets: blurryAssets,
                        groupsFoundCount: latestGroups.count,
                        reviewablePhotosCount: reviewableCount,
                        reclaimableBytesFoundSoFar: reclaimableBytes,
                        hasPartialResults: !isComplete && reviewableCount > 0,
                        isComplete: isComplete,
                        evaluatedAssetIDs: evaluatedAssetIDs,
                        targetAssetIDs: targetAssetIDs,
                        unanalyzedAssetIDs: unanalyzedAssetIDs,
                        committedProcessedPhotoCount: processedCount,
                        committedAnalyzedPhotoCount: analyzedPhotoCount,
                        committedUnanalyzedPhotoCount: unanalyzedPhotoCount
                    )
                )
                await Task.yield()
            }

            await performMLRetentionAfterSuccessfulScan(
                activeAssetIDs: Set(allAssets.map(\.localIdentifier))
            )
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func performMLRetentionAfterSuccessfulScan(
        activeAssetIDs: Set<String>
    ) async {
        guard !Task.isCancelled else { return }
        do {
            _ = try await mlBridge.performRetention(activeAssetIDs: activeAssetIDs)
        } catch {
            // Retention is maintenance, not scan evidence. The bridge records the
            // failure for diagnostics while completed scan results remain usable.
        }
    }

    private func waitWhilePaused() async throws {
        while isPaused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
    }

    private nonisolated static func analyzeAsset(
        _ asset: PHAsset,
        allowNetworkAccess: Bool
    ) async -> PhotoScanAssetAnalysis {
        var loadedImage = await asset.loadImage(
            targetSize: CGSize(width: 224, height: 224),
            deliveryMode: .fastFormat,
            allowNetwork: allowNetworkAccess,
            contentMode: .aspectFill,
            // Degraded PhotoKit thumbnails can be soft because the original is
            // still in iCloud. They are not valid evidence of camera blur.
            acceptsDegradedResult: false,
            timeout: 4
        )
        if loadedImage == nil {
            // fastFormat serves pre-generated derivatives; assets without one
            // (fresh imports, some local originals) fail with "no resource
            // found" even though the original is on device. Decoding the
            // original is slower but keeps such photos analyzable.
            loadedImage = await asset.loadImage(
                targetSize: CGSize(width: 224, height: 224),
                deliveryMode: .highQualityFormat,
                allowNetwork: allowNetworkAccess,
                contentMode: .aspectFill,
                acceptsDegradedResult: false,
                timeout: allowNetworkAccess ? 15 : 6
            )
        }
        guard let image = loadedImage, let cgImage = image.cgImage else {
            return .unavailable
        }

        var keeperSignals = makeKeeperSignals(from: cgImage, asset: asset)
        if let sharpness = keeperSignals?.sharpness,
           sharpness <= PhotoScanDefaults.blurryPhotoSharpnessCeiling {
            // Confirm a low-resolution blur signal against a larger,
            // non-degraded representation. If it is unavailable locally, leave
            // the asset unanalyzed for blur instead of blaming an iCloud cache.
            let confirmationImage = await asset.loadImage(
                targetSize: CGSize(width: 1_024, height: 1_024),
                deliveryMode: .highQualityFormat,
                allowNetwork: allowNetworkAccess,
                contentMode: .aspectFit,
                acceptsDegradedResult: false,
                timeout: allowNetworkAccess ? 15 : 4
            )
            keeperSignals = confirmationImage?.cgImage.flatMap {
                makeKeeperSignals(from: $0, asset: asset)
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = PhotoMLBridge.makePinnedFeaturePrintRequest()
        do {
            try handler.perform([request])
            let rawObservation = request.results?.first as? VNFeaturePrintObservation
            let observation = rawObservation.flatMap {
                PhotoEmbeddingContract.isCompatibleObservation(
                    elementCount: $0.elementCount,
                    byteCount: $0.data.count
                ) ? $0 : nil
            }
            return PhotoScanAssetAnalysis(
                observation: observation,
                embedding: observation?.data,
                perceptualHash: makePerceptualHash(from: cgImage),
                keeperSignals: keeperSignals
            )
        } catch {
            return PhotoScanAssetAnalysis(
                observation: nil,
                embedding: nil,
                perceptualHash: makePerceptualHash(from: cgImage),
                keeperSignals: keeperSignals
            )
        }
    }

    private nonisolated static func makePerceptualHash(from image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 64)
        guard let context = CGContext(
            data: &pixels,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var hash: UInt64 = 0
        for (index, pixel) in pixels.enumerated() where Int(pixel) >= average {
            hash |= UInt64(1) << index
        }
        return hash
    }

    private nonisolated static func makeKeeperSignals(
        from image: CGImage,
        asset: PHAsset
    ) -> KeeperSignals? {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var laplacianTotal = 0.0
        var horizontalGradientTotal = 0.0
        var verticalGradientTotal = 0.0
        var sampleCount = 0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let index = y * side + x
                let center = Int(pixels[index])
                let left = Int(pixels[index - 1])
                let right = Int(pixels[index + 1])
                let above = Int(pixels[index - side])
                let below = Int(pixels[index + side])
                laplacianTotal += Double(abs(4 * center - left - right - above - below))
                horizontalGradientTotal += Double(abs(right - left))
                verticalGradientTotal += Double(abs(below - above))
                sampleCount += 1
            }
        }

        let meanLuminance = Double(pixels.reduce(0) { $0 + Int($1) })
            / Double(max(pixels.count, 1))
            / 255
        let clippedCount = pixels.reduce(0) { count, value in
            count + ((value < 8 || value > 247) ? 1 : 0)
        }
        let clippingRatio = Double(clippedCount) / Double(max(pixels.count, 1))
        let centeredExposure = 1 - min(abs(meanLuminance - 0.5) * 2, 1)
        let exposureScore = clamp(
            centeredExposure - clippingRatio * 1.5,
            lower: 0,
            upper: 1
        )

        let averageLaplacian = laplacianTotal / Double(max(sampleCount, 1))
        let sharpness = clamp(averageLaplacian / 45, lower: 0, upper: 1)
        let blurPenalty = 1 - sharpness
        let maxGradient = max(horizontalGradientTotal, verticalGradientTotal, 1)
        let directionalImbalance = abs(
            horizontalGradientTotal - verticalGradientTotal
        ) / maxGradient
        let motionBlurPenalty = clamp(
            blurPenalty * 0.30 + directionalImbalance * 0.15,
            lower: 0,
            upper: 1
        )

        let pixelsCount = Double(max(asset.pixelWidth, 1))
            * Double(max(asset.pixelHeight, 1))
        let resolutionScore = min(log10(pixelsCount) / 8, 1)
        let aspect = Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1))
        let aspectDistance = min(
            abs(aspect - 1),
            abs(aspect - 4.0 / 3.0),
            abs(aspect - 3.0 / 4.0)
        )

        return KeeperSignals(
            sharpness: sharpness,
            blurPenalty: blurPenalty,
            motionBlurPenalty: motionBlurPenalty,
            eyesOpenScore: nil,
            expressionScore: nil,
            exposureScore: exposureScore,
            favoriteBonus: asset.isFavorite ? 0.08 : 0,
            editedBonusOrPenalty: asset.isEdited ? 0.04 : 0,
            framingScore: max(0, 1 - min(aspectDistance, 1)),
            resolutionTiebreaker: resolutionScore * 0.2
        )
    }

    private nonisolated func comparisonCandidateIDs(
        for descriptor: SimilarityAssetDescriptor,
        perceptualHash: UInt64?,
        orderedProcessedIDs: [String],
        descriptorsByID: [String: SimilarityAssetDescriptor],
        screenshotIDsByHash: [UInt64: [String]],
        burstIDsByIdentifier: [String: [String]]
    ) -> [String] {
        if descriptor.isScreenshot {
            guard let perceptualHash else { return [] }
            return Array(
                (screenshotIDsByHash[perceptualHash] ?? [])
                    .suffix(SimilarityThresholds.maxFeatureComparisonsPerAsset)
            )
        }

        if let burstIdentifier = descriptor.burstIdentifier {
            return Array(
                (burstIDsByIdentifier[burstIdentifier] ?? [])
                    .suffix(SimilarityThresholds.maxBurstAssetsPerCluster - 1)
            )
        }

        return PhotoScanCandidateSelector.genericCandidateIDs(
            for: descriptor,
            orderedProcessedIDs: orderedProcessedIDs,
            descriptorsByID: descriptorsByID
        )
    }

    private nonisolated func featureDistance(
        lhs: VNFeaturePrintObservation?,
        rhs: VNFeaturePrintObservation?
    ) -> Double? {
        guard let lhs, let rhs, lhs.elementCount == rhs.elementCount else {
            return nil
        }
        var distance: Float = 0
        do {
            try lhs.computeDistance(&distance, to: rhs)
            return PhotoFeatureDistanceNormalizer.normalizedDistance(
                rawDistance: Double(distance),
                elementCount: lhs.elementCount
            )
        } catch {
            return nil
        }
    }

    private func makeGroups(
        assetsByID: [String: PHAsset],
        descriptorsByID: [String: SimilarityAssetDescriptor],
        keeperSignalsByID: [String: KeeperSignals],
        pairSignals: [SimilarityPairKey: SimilaritySignals],
        pairResults: [SimilarityPairKey: PairEligibilityResult],
        preferenceProfile: PhotoPreferenceProfile,
        cachedGroups: inout [PhotoScanGroupCacheKey: CachedPhotoScanGroup]
    ) async -> [PhotoGroup] {
        let descriptors = descriptorsByID.values.sorted {
            let lhsDate = $0.captureTimestamp ?? .distantPast
            let rhsDate = $1.captureTimestamp ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return $0.id < $1.id
        }
        let clusterIDs = candidateGraph.formClusters(
            descriptors: descriptors,
            pairResults: pairResults
        )
        let activeCacheKeys = Set(
            clusterIDs.map { PhotoScanGroupCacheKey(memberIDs: $0) }
        )
        cachedGroups = cachedGroups.filter { activeCacheKeys.contains($0.key) }

        var groups: [PhotoGroup] = []
        groups.reserveCapacity(clusterIDs.count)
        for ids in clusterIDs {
            guard !Task.isCancelled else { break }
            let cacheKey = PhotoScanGroupCacheKey(memberIDs: ids)
            if let cachedGroup = cachedGroups[cacheKey] {
                // Pair and keeper evidence is immutable once every member in this
                // exact cluster has been processed. Reusing the complete result
                // preserves the same explicit keeper/delete plan and group ID.
                if let group = cachedGroup.group {
                    groups.append(group)
                }
                continue
            }

            let assets = ids.compactMap { assetsByID[$0] }
            let clusterDescriptors = ids.compactMap { descriptorsByID[$0] }
            guard assets.count == ids.count, clusterDescriptors.count == ids.count else {
                continue
            }

            var clusterPairSignals: [SimilarityPairKey: SimilaritySignals] = [:]
            for lhsIndex in ids.indices {
                for rhsIndex in ids.indices where rhsIndex > lhsIndex {
                    let key = SimilarityPairKey(ids[lhsIndex], ids[rhsIndex])
                    if let signals = pairSignals[key] {
                        clusterPairSignals[key] = signals
                    }
                }
            }

            let keeperSignals = Dictionary(
                uniqueKeysWithValues: assets.map { asset in
                    (
                        asset.localIdentifier,
                        keeperSignalsByID[asset.localIdentifier]
                            ?? SimilaritySignalBuilder.keeperSignals(for: asset)
                    )
                }
            )
            let input = SimilarityClusterInput(
                assets: clusterDescriptors,
                pairwiseSignals: clusterPairSignals,
                keeperSignalsByAssetID: keeperSignals
            )
            let evaluation = await similarityPolicyEngine.evaluateCluster(input)
            let classification = evaluation.groupResult
            guard classification.bucket != .notSimilar,
                  let reason = classification.bucket.photoGroupReason else {
                cachedGroups[cacheKey] = CachedPhotoScanGroup(group: nil)
                continue
            }

            let containsScreenshot = assets.contains {
                $0.mediaSubtypes.contains(.photoScreenshot)
            }
            let adjustment = preferenceAdjustmentService.adjust(
                PreferenceAdjustedRecommendationInput(
                    bucket: classification.bucket,
                    groupType: reason.defaultGroupType,
                    confidence: classification.confidence.photoGroupConfidence,
                    suggestedAction: classification.action.photoGroupAction,
                    keeperRankingResult: evaluation.keeperRankingResult,
                    preferenceProfile: preferenceProfile,
                    containsScreenshot: containsScreenshot,
                    containsBurst: assets.contains { $0.burstIdentifier != nil },
                    containsEdited: assets.contains(where: \.isEdited),
                    containsFavorite: assets.contains(where: \.isFavorite),
                    assetCount: assets.count
                )
            )

            let hasCompleteKeeperEvidence = ids.allSatisfy {
                keeperSignalsByID[$0] != nil
            }
            let finalAction = reason == .visuallySimilar || !hasCompleteKeeperEvidence
                ? SimilarRecommendedAction.reviewManually
                : adjustment.adjustedSuggestedAction
            let finalDeleteCandidateIDs = finalAction == .keepBestTrashRest
                ? classification.deleteCandidateIDs
                : []
            let keeperID = evaluation.keeperRankingResult.keeperAssetID
            let candidates = makeCandidates(
                assets: assets,
                ranking: evaluation.keeperRankingResult,
                deleteCandidateIDs: finalDeleteCandidateIDs,
                exposeDeleteCandidates: finalAction == .keepBestTrashRest
            )
            let keeperReasons = keeperID.flatMap {
                evaluation.keeperRankingResult.reasonsByAssetID[$0]
            } ?? []
            let reasons = (
                classification.reasons
                    + adjustment.reasons
                    + keeperReasons
                    + (hasCompleteKeeperEvidence
                        ? []
                        : ["Technical keeper evidence is incomplete; review manually."])
            ).uniquePreservingOrder()
            let finalBlockerFlags = Set(
                classification.blockerFlags
                    + (hasCompleteKeeperEvidence ? [] : [.lowKeeperEvidence])
            )
            .sorted { $0.rawValue < $1.rawValue }

            let group = PhotoGroup(
                assets: assets.sortedByCreationDate(),
                similarity: Float(classification.scoreBreakdown.similarityScore),
                reason: reason,
                groupType: reason.defaultGroupType,
                groupConfidence: adjustment.adjustedConfidence,
                reviewState: .unreviewed,
                recommendedAction: finalAction,
                keeperAssetID: keeperID,
                deleteCandidateIDs: finalDeleteCandidateIDs,
                bestShotPhotoId: keeperID,
                groupReasonsSummary: reasons,
                blockerFlags: finalBlockerFlags,
                scoreBreakdown: classification.scoreBreakdown,
                preferenceQueuePriority: adjustment.queuePriorityDelta,
                preferenceAdjustmentReasons: adjustment.reasons,
                candidates: candidates,
                reclaimableBytes: estimatedReclaimableBytes(
                    for: assets,
                    deleteCandidateIDs: finalDeleteCandidateIDs
                )
            )
            cachedGroups[cacheKey] = CachedPhotoScanGroup(group: group)
            groups.append(group)
        }

        return groups.sorted { lhs, rhs in
            let lhsPriority = lhs.preferenceQueuePriority ?? 0
            let rhsPriority = rhs.preferenceQueuePriority ?? 0
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            let lhsDate = lhs.captureDateRange?.start ?? .distantPast
            let rhsDate = rhs.captureDateRange?.start ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private nonisolated func makeCandidates(
        assets: [PHAsset],
        ranking: KeeperRankingResult,
        deleteCandidateIDs: [String],
        exposeDeleteCandidates: Bool
    ) -> [SimilarPhotoCandidate] {
        let assetsByID = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) }
        )
        let rankedIDs = (
            ranking.rankedAssetIDs
                + assets.map(\.localIdentifier).sorted()
        ).uniquePreservingOrder()
        let deleteIDSet = Set(deleteCandidateIDs)

        return rankedIDs.compactMap { assetID in
            guard let asset = assetsByID[assetID] else { return nil }
            let isKeeper = assetID == ranking.keeperAssetID
            let signals = ranking.scoreBreakdownByAssetID[assetID]
                ?? SimilaritySignalBuilder.keeperSignals(for: asset)
            var issues: [IssueFlag] = []
            if signals.blurPenalty > 0.45 { issues.append(.softFocus) }
            if signals.motionBlurPenalty > 0.45 { issues.append(.motionBlur) }
            if signals.framingScore < 0.42 { issues.append(.worseFraming) }
            if !isKeeper && issues.isEmpty { issues.append(.lowConfidence) }

            let isDeleteCandidate = exposeDeleteCandidates
                && !isKeeper
                && deleteIDSet.contains(assetID)
            return SimilarPhotoCandidate(
                photoId: assetID,
                assetReference: assetID,
                captureTimestamp: asset.creationDate,
                isBestShot: isKeeper,
                bestShotScore: ranking.scoreByAssetID[assetID] ?? 0,
                bestShotReasons: ranking.reasonsByAssetID[assetID] ?? [],
                issueFlags: isKeeper ? [] : issues,
                isProtected: false,
                isSelectedForTrash: isDeleteCandidate,
                isViewed: false,
                selectionState: isKeeper
                    ? .keep
                    : (isDeleteCandidate ? .trash : .undecided),
                technicalScores: SimilarTechnicalScores(
                    sharpness: signals.sharpness,
                    focus: max(0, signals.sharpness - signals.blurPenalty),
                    exposure: signals.exposureScore,
                    framing: signals.framingScore
                )
            )
        }
    }

    private nonisolated func estimatedReclaimableBytes(
        for assets: [PHAsset],
        deleteCandidateIDs: [String]
    ) -> Int64 {
        let deleteIDSet = Set(deleteCandidateIDs)
        return assets.reduce(into: Int64(0)) { total, asset in
            if deleteIDSet.contains(asset.localIdentifier) {
                total += asset.estimatedFileSize
            }
        }
    }

    private nonisolated func prioritizedAssets(
        from assets: [PHAsset],
        mode: CleanupMode
    ) -> [PHAsset] {
        switch mode {
        case .speedClean:
            let limit = min(assets.count, min(500, max(80, assets.count / 5)))
            let chronological = assets.sortedByCreationDate()
            var inCluster: [PHAsset] = []
            var isolated: [PHAsset] = []
            for (index, asset) in chronological.enumerated() {
                let date = asset.creationDate ?? .distantPast
                let previousIsClose = index > 0
                    && abs(date.timeIntervalSince(
                        chronological[index - 1].creationDate ?? .distantPast
                    )) < ScanWindows.clusterWindowSeconds
                let nextIsClose = index < chronological.count - 1
                    && abs(date.timeIntervalSince(
                        chronological[index + 1].creationDate ?? .distantPast
                    )) < ScanWindows.clusterWindowSeconds
                if previousIsClose || nextIsClose {
                    inCluster.append(asset)
                } else {
                    isolated.append(asset)
                }
            }

            var result = Array(inCluster.sortedByCreationDate(ascending: false).prefix(limit))
            if result.count < limit {
                let seenIDs = Set(result.map(\.localIdentifier))
                let recentCutoff = Calendar.current.date(
                    byAdding: .day,
                    value: ScanWindows.recentPhotosDays,
                    to: Date()
                ) ?? .distantPast
                let priorityByID = Dictionary(
                    uniqueKeysWithValues: isolated.map {
                        (
                            $0.localIdentifier,
                            assetPriority($0, recentCutoff: recentCutoff)
                        )
                    }
                )
                result.append(
                    contentsOf: isolated
                        .filter { !seenIDs.contains($0.localIdentifier) }
                        .sorted { lhs, rhs in
                            let lhsPriority = priorityByID[lhs.localIdentifier] ?? 0
                            let rhsPriority = priorityByID[rhs.localIdentifier] ?? 0
                            if lhsPriority != rhsPriority {
                                return lhsPriority > rhsPriority
                            }
                            let lhsDate = lhs.creationDate ?? .distantPast
                            let rhsDate = rhs.creationDate ?? .distantPast
                            if lhsDate != rhsDate { return lhsDate > rhsDate }
                            return lhs.localIdentifier < rhs.localIdentifier
                        }
                        .prefix(limit - result.count)
                )
            }
            return result.sortedByCreationDate()
        case .deepClean:
            // Deep Clean analyzes the full library chronologically. Priority
            // sorting here would be immediately discarded.
            return assets.sortedByCreationDate()
        }
    }

    private nonisolated func incrementalAssets(
        from assets: [PHAsset],
        requiredAssetIDs: Set<String>
    ) -> [PHAsset] {
        guard !requiredAssetIDs.isEmpty else { return [] }

        let chronological = assets.sortedByCreationDate()
        let requiredAssets = chronological.filter {
            requiredAssetIDs.contains($0.localIdentifier)
        }
        guard !requiredAssets.isEmpty else { return [] }

        var includedIDs = Set(requiredAssets.map(\.localIdentifier))

        let requiredBurstIDs = Set(requiredAssets.compactMap(\.burstIdentifier))
        if !requiredBurstIDs.isEmpty {
            for candidate in chronological {
                if let burstID = candidate.burstIdentifier,
                   requiredBurstIDs.contains(burstID) {
                    includedIDs.insert(candidate.localIdentifier)
                }
            }
        }

        // Merge required capture windows once, then sweep the chronological
        // library once. The old nested loop became billions of checks when a
        // large interrupted scan resumed.
        let window = SimilarityThresholds.visualSessionWindowSeconds
        let requiredDates = requiredAssets.compactMap(\.creationDate).sorted()
        var mergedWindows: [DateInterval] = []
        for date in requiredDates {
            let interval = DateInterval(
                start: date.addingTimeInterval(-window),
                end: date.addingTimeInterval(window)
            )
            if let last = mergedWindows.last,
               interval.start <= last.end {
                mergedWindows[mergedWindows.count - 1] = DateInterval(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                mergedWindows.append(interval)
            }
        }

        var windowIndex = 0
        for candidate in chronological {
            guard let date = candidate.creationDate,
                  windowIndex < mergedWindows.count else {
                continue
            }
            while windowIndex < mergedWindows.count,
                  date > mergedWindows[windowIndex].end {
                windowIndex += 1
            }
            if windowIndex < mergedWindows.count,
               mergedWindows[windowIndex].contains(date) {
                includedIDs.insert(candidate.localIdentifier)
            }
        }

        struct Dimensions: Hashable {
            let width: Int
            let height: Int
        }
        let requiredScreenshotDimensions = Set(
            requiredAssets.compactMap { asset -> Dimensions? in
                guard asset.mediaSubtypes.contains(.photoScreenshot) else {
                    return nil
                }
                return Dimensions(width: asset.pixelWidth, height: asset.pixelHeight)
            }
        )
        if !requiredScreenshotDimensions.isEmpty {
            var contextCounts: [Dimensions: Int] = [:]
            for candidate in chronological.reversed()
            where candidate.mediaSubtypes.contains(.photoScreenshot) {
                let dimensions = Dimensions(
                    width: candidate.pixelWidth,
                    height: candidate.pixelHeight
                )
                guard requiredScreenshotDimensions.contains(dimensions),
                      !includedIDs.contains(candidate.localIdentifier),
                      contextCounts[dimensions, default: 0]
                        < SimilarityThresholds.maxFeatureComparisonsPerAsset else {
                    continue
                }
                includedIDs.insert(candidate.localIdentifier)
                contextCounts[dimensions, default: 0] += 1
            }
        }

        return chronological.filter {
            includedIDs.contains($0.localIdentifier)
        }
    }

    private nonisolated func assetPriority(
        _ asset: PHAsset,
        recentCutoff: Date
    ) -> Int {
        var score = 0
        if asset.mediaSubtypes.contains(.photoScreenshot) { score += 100 }
        if asset.burstIdentifier != nil { score += 80 }
        let pixels = Int64(asset.pixelWidth) * Int64(asset.pixelHeight)
        if pixels >= 12_000_000 { score += 40 }
        if pixels >= 8_000_000 { score += 20 }
        if let date = asset.creationDate, date > recentCutoff {
            score += 10
        }
        return score
    }
}

enum ScanError: Error {
    case permissionDenied
}

enum PhotoScanDefaults {
    static let analysisBatchSize = 8
    // iCloud downloads require an explicit caller opt-in.
    static let allowNetworkAccess = false
    // This category is review-only. Keep the initial cutoff conservative until
    // device telemetry can separate intentional softness from accidental blur.
    static let blurryPhotoSharpnessCeiling = 0.22
}

enum PhotoReviewCategory: Equatable, Sendable {
    case screenshot
    case blurry
}

enum PhotoReviewCategoryClassifier {
    static func classify(
        isScreenshot: Bool,
        sharpness: Double?
    ) -> PhotoReviewCategory? {
        if isScreenshot {
            return .screenshot
        }
        guard let sharpness,
              sharpness <= PhotoScanDefaults.blurryPhotoSharpnessCeiling else {
            return nil
        }
        return .blurry
    }

    static func reviewableCount(
        groups: [PhotoGroup],
        screenshotAssets: [PHAsset],
        blurryAssets: [PHAsset]
    ) -> Int {
        let groupedAssetIDs = Set(groups.flatMap(\.assets).map(\.localIdentifier))
        let groupReviewCount = groups.reduce(0) {
            $0 + max($1.assets.count - 1, 0)
        }
        let categoryOnlyIDs = Set(
            (screenshotAssets + blurryAssets).map(\.localIdentifier)
        ).subtracting(groupedAssetIDs)
        return groupReviewCount + categoryOnlyIDs.count
    }
}

private struct AssetWorkItem: @unchecked Sendable {
    let asset: PHAsset
}

private struct AnalyzedAsset: @unchecked Sendable {
    let assetID: String
    let featureValue: PhotoScanAssetAnalysis
}

private struct CandidatePairEvidence {
    let key: SimilarityPairKey
    let signals: SimilaritySignals
    let result: PairEligibilityResult
    let featureDistance: Double?
    let wasCacheHit: Bool
}

struct PhotoScanPairDistanceResolution: Equatable, Sendable {
    let distance: Double?
    let wasCacheHit: Bool
}

enum PhotoScanPairDistanceResolver {
    static func cachedResolution(
        key: SimilarityPairKey,
        cachedRecords: [SimilarityPairKey: PairSimilarityRecord]
    ) -> PhotoScanPairDistanceResolution? {
        guard let cached = cachedRecords[key],
              SimilarityPairKey(cached.lhsAssetID, cached.rhsAssetID) == key,
              cached.embeddingVersion == PhotoEmbeddingContract.embeddingVersion,
              cached.featureDistance.isFinite,
              cached.featureDistance >= 0 else {
            return nil
        }

        return PhotoScanPairDistanceResolution(
            distance: cached.featureDistance,
            wasCacheHit: true
        )
    }
}

enum PhotoFeatureDistanceNormalizer {
    static func normalizedDistance(
        rawDistance: Double,
        elementCount: Int
    ) -> Double? {
        guard rawDistance.isFinite, rawDistance >= 0, elementCount > 0 else {
            return nil
        }

        // Vision reports an L2 distance across the whole feature vector.
        // RMS normalization keeps policy thresholds stable per feature rather
        // than accidentally treating a raw 2,048-dimensional value as 0...1.
        return rawDistance / sqrt(Double(elementCount))
    }
}

struct PhotoScanGroupCacheKey: Hashable, Sendable {
    let memberIDs: [String]

    init(memberIDs: [String]) {
        self.memberIDs = memberIDs.sorted()
    }
}

private struct CachedPhotoScanGroup {
    let group: PhotoGroup?
}

enum PhotoScanCandidateSelector {
    static func genericCandidateIDs(
        for descriptor: SimilarityAssetDescriptor,
        orderedProcessedIDs: [String],
        descriptorsByID: [String: SimilarityAssetDescriptor]
    ) -> [String] {
        guard let currentDate = descriptor.captureTimestamp else { return [] }

        let inspectedIDs = orderedProcessedIDs
            .suffix(SimilarityThresholds.maxCandidateAssetsInspected)
            .reversed()
        var primaryCandidates: [String] = []
        var extendedCandidates: [String] = []
        primaryCandidates.reserveCapacity(
            SimilarityThresholds.maxFeatureComparisonsPerAsset
        )
        extendedCandidates.reserveCapacity(
            SimilarityThresholds.reservedExtendedFeatureComparisonsPerAsset
        )

        for candidateID in inspectedIDs {
            guard candidateID != descriptor.id,
                  let candidate = descriptorsByID[candidateID],
                  !candidate.isScreenshot,
                  let candidateDate = candidate.captureTimestamp,
                  abs(descriptor.aspectRatio - candidate.aspectRatio)
                    <= SimilarityThresholds.majorAspectRatioMismatch else {
                continue
            }

            let timeDelta = abs(currentDate.timeIntervalSince(candidateDate))
            // Assets are processed in ascending capture order. Once the reversed
            // walk crosses the session window, every remaining candidate is older.
            if currentDate >= candidateDate,
               timeDelta > SimilarityThresholds.extendedVisualSessionWindowSeconds {
                break
            }
            if timeDelta <= SimilarityThresholds.visualSessionWindowSeconds {
                primaryCandidates.append(candidateID)
            } else if timeDelta <= SimilarityThresholds.extendedVisualSessionWindowSeconds {
                extendedCandidates.append(candidateID)
            }
        }

        // Reserve a small part of the bounded comparison budget for strong
        // 30-60 minute matches so a dense recent burst cannot starve them.
        let maxComparisons = SimilarityThresholds.maxFeatureComparisonsPerAsset
        let extendedCount = min(
            extendedCandidates.count,
            min(
                SimilarityThresholds.reservedExtendedFeatureComparisonsPerAsset,
                maxComparisons
            )
        )
        let primaryCount = min(
            primaryCandidates.count,
            maxComparisons - extendedCount
        )

        var candidates = Array(primaryCandidates.prefix(primaryCount))
        candidates.append(
            contentsOf: extendedCandidates.prefix(maxComparisons - candidates.count)
        )
        return candidates
    }
}

enum PhotoScanRefreshSchedule {
    static func nextThreshold(
        after processedCount: Int,
        currentThreshold: Int,
        targetCount: Int,
        minimumStride: Int
    ) -> Int {
        guard processedCount < targetCount else { return targetCount }
        return min(
            targetCount,
            max(processedCount + minimumStride, currentThreshold * 2)
        )
    }
}
