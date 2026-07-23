import Photos
import UIKit
import Vision
import XCTest
@testable import iOSCleanup

final class PhotoScanEngineTests: XCTestCase {
    private let graph = SimilarityCandidateGraph()

    @MainActor
    func testPhotoScanEngineConstructionDoesNotLoadCoreMLModels() async {
        let keeperStatusBefore = await MLKeeperRankingService.shared.loadStatus()
        let groupStatusBefore = await MLGroupActionService.shared.loadStatus()

        _ = PhotoScanEngine()

        let keeperStatusAfter = await MLKeeperRankingService.shared.loadStatus()
        let groupStatusAfter = await MLGroupActionService.shared.loadStatus()
        XCTAssertEqual(keeperStatusAfter, keeperStatusBefore)
        XCTAssertEqual(groupStatusAfter, groupStatusBefore)
    }

    func testOptionalMLRankerFactoryIsLazy() {
        let factoryProbe = LockedInvocationCounter()

        _ = LazyOptionalMLKeeperRankingService(
            optionalRankerFactory: { conservativeRanker in
                factoryProbe.increment()
                return conservativeRanker
            }
        )

        XCTAssertEqual(factoryProbe.value, 0)
    }

    func testPinnedVisionFeaturePrintScaleUsingDeterministicFixtures() throws {
        let referenceImage = makeVisionFixture(style: .reference)
        let matchingObservation: VNFeaturePrintObservation
        let repeatedObservation: VNFeaturePrintObservation
        let unrelatedObservation: VNFeaturePrintObservation
        do {
            matchingObservation = try featurePrintObservation(for: referenceImage)
            repeatedObservation = try featurePrintObservation(for: referenceImage)
            unrelatedObservation = try featurePrintObservation(
                for: makeVisionFixture(style: .unrelated)
            )
        } catch {
#if targetEnvironment(simulator)
            let nsError = error as NSError
            if nsError.domain == "com.apple.Vision", nsError.code == 9 {
                throw XCTSkip(
                    "This simulator runtime cannot create a Vision inference context; run the scale fixture on device."
                )
            }
#endif
            throw error
        }

        var repeatedDistance: Float = 0
        try matchingObservation.computeDistance(
            &repeatedDistance,
            to: repeatedObservation
        )
        var unrelatedDistance: Float = 0
        try matchingObservation.computeDistance(
            &unrelatedDistance,
            to: unrelatedObservation
        )

        XCTAssertLessThanOrEqual(repeatedDistance, 0.001)
        XCTAssertGreaterThan(
            unrelatedDistance,
            Float(SimilarityThresholds.maxNearDuplicateFeatureDistance)
        )
    }

    func testPairDistanceResolverReportsCacheHit() {
        let key = SimilarityPairKey("left", "right")
        let cachedRecord = PairSimilarityRecord(
            lhsAssetID: "right",
            rhsAssetID: "left",
            featureDistance: 0.04,
            timeDeltaSeconds: 1,
            isBurstPair: false,
            bucket: SimilarityBucket.nearDuplicate.rawValue,
            similarityScore: 0.92
        )

        let resolution = PhotoScanPairDistanceResolver.cachedResolution(
            key: key,
            cachedRecords: [key: cachedRecord]
        )

        XCTAssertEqual(
            resolution,
            PhotoScanPairDistanceResolution(
                distance: 0.04,
                wasCacheHit: true
            )
        )
    }

    func testTuningConstantsStayPrecisionFirstAndBounded() {
        XCTAssertFalse(PhotoScanDefaults.allowNetworkAccess)
        XCTAssertLessThan(
            SimilarityThresholds.maxNearDuplicateFeatureDistance,
            SimilarityThresholds.maxVisualSimilarFeatureDistance
        )
        XCTAssertLessThanOrEqual(
            SimilarityThresholds.maxFeatureComparisonsPerAsset,
            SimilarityThresholds.maxCandidateAssetsInspected
        )
        XCTAssertLessThanOrEqual(
            SimilarityThresholds.maxRetainedGenericPairEdgesPerAsset,
            SimilarityThresholds.maxFeatureComparisonsPerAsset
        )
        XCTAssertLessThan(
            SimilarityThresholds.nearDuplicateWindowSeconds,
            SimilarityThresholds.visualSessionWindowSeconds
        )
        XCTAssertGreaterThanOrEqual(
            SimilarityThresholds.nearDuplicateAutoDeleteScoreFloor,
            SimilarityThresholds.nearDuplicateClusterFloor
        )
        XCTAssertGreaterThanOrEqual(
            SimilarityThresholds.burstAutoDeleteScoreFloor,
            SimilarityThresholds.burstPairEligibilityScoreFloor
        )
        XCTAssertGreaterThanOrEqual(
            SimilarityThresholds.maxRetainedScreenshotFeaturePrints,
            SimilarityThresholds.maxFeatureComparisonsPerAsset
        )
    }

    func testPartialGroupRefreshScheduleGrowsGeometrically() {
        var threshold = 24
        var thresholds = [threshold]
        for processedCount in [24, 48, 96, 192, 384, 768] {
            threshold = PhotoScanRefreshSchedule.nextThreshold(
                after: processedCount,
                currentThreshold: threshold,
                targetCount: 1_000,
                minimumStride: 24
            )
            thresholds.append(threshold)
        }

        XCTAssertEqual(thresholds, [24, 48, 96, 192, 384, 768, 1_000])
    }

    func testScanUpdateSurfacesIncompleteAnalysisCoverage() {
        let update = PhotoScanUpdate(
            mode: .deepClean,
            libraryTotalCount: 12,
            scanTargetCount: 10,
            processedPhotoCount: 10,
            analyzedPhotoCount: 3,
            unanalyzedPhotoCount: 7,
            progressFraction: 1,
            groups: [],
            groupsFoundCount: 0,
            reviewablePhotosCount: 0,
            reclaimableBytesFoundSoFar: 0,
            hasPartialResults: false,
            isComplete: true
        )

        XCTAssertEqual(
            update.processedPhotoCount,
            update.analyzedPhotoCount + update.unanalyzedPhotoCount
        )
        XCTAssertTrue(update.hasUnanalyzedPhotos)
    }

    func testInjectedAssetProviderCompletesDegradedScanWithoutFalseCleanResult() async throws {
        let assets = (0..<9).map {
            PhotoScanTestAsset(
                localIdentifier: "degraded-\($0)",
                creationDate: Date(timeIntervalSinceReferenceDate: TimeInterval($0))
            )
        }
        let invocationCounter = LockedInvocationCounter()
        let engine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(assets: assets),
            assetAnalyzer: { _, allowNetworkAccess in
                XCTAssertFalse(allowNetworkAccess)
                invocationCounter.increment()
                return .unavailable
            }
        )

        var finalUpdate: PhotoScanUpdate?
        for try await update in engine.scan(mode: .deepClean) {
            if update.isComplete {
                finalUpdate = update
            }
        }

        XCTAssertEqual(invocationCounter.value, assets.count)
        XCTAssertEqual(finalUpdate?.processedPhotoCount, assets.count)
        XCTAssertEqual(finalUpdate?.analyzedPhotoCount, 0)
        XCTAssertEqual(finalUpdate?.unanalyzedPhotoCount, assets.count)
        XCTAssertTrue(finalUpdate?.hasUnanalyzedPhotos == true)
        XCTAssertTrue(finalUpdate?.groups.isEmpty == true)
    }

    func testScanCancellationPropagatesIntoInFlightAssetAnalysis() async {
        let assets = (0..<12).map {
            PhotoScanTestAsset(
                localIdentifier: "cancel-\($0)",
                creationDate: Date(timeIntervalSinceReferenceDate: TimeInterval($0))
            )
        }
        let probe = ScanAnalyzerProbe()
        let engine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(assets: assets),
            assetAnalyzer: { _, _ in
                await probe.analyze()
            }
        )
        let stream = engine.scan(mode: .deepClean)
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the expected terminal state.
            }
        }

        for _ in 0..<100 {
            if await probe.startedCount >= 4 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        consumer.cancel()
        await consumer.value

        for _ in 0..<100 {
            if await probe.cancelledCount > 0 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let startedCount = await probe.startedCount
        let cancelledCount = await probe.cancelledCount
        XCTAssertGreaterThanOrEqual(startedCount, 4)
        XCTAssertGreaterThan(cancelledCount, 0)
    }

    func testAnalysisCacheSchemaFourRoundTripPreservesCoverageCounts() async throws {
        try await withIsolatedAnalysisCacheFile { _ in
            let cache = PhotoAnalysisCache()
            let snapshot = makeAnalysisSnapshot(
                analyzedPhotoCount: 7,
                unanalyzedPhotoCount: 3
            )

            await cache.saveSnapshot(snapshot)
            let loaded = await cache.loadSnapshot()

            XCTAssertEqual(loaded?.schemaVersion, 4)
            XCTAssertEqual(loaded?.processedPhotoCount, 10)
            XCTAssertEqual(loaded?.analyzedPhotoCount, 7)
            XCTAssertEqual(loaded?.unanalyzedPhotoCount, 3)
            XCTAssertEqual(loaded?.cleanupMode, .deepClean)
        }
    }

    func testAnalysisCacheRejectsOlderSchemaVersion() async throws {
        try await withIsolatedAnalysisCacheFile { cacheURL in
            let cache = PhotoAnalysisCache()
            let snapshot = makeAnalysisSnapshot(
                analyzedPhotoCount: 8,
                unanalyzedPhotoCount: 2
            )
            let encoded = try JSONEncoder().encode(snapshot)
            guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                XCTFail("Snapshot should encode as a JSON object")
                return
            }
            object["schemaVersion"] = CachedPhotoAnalysisSnapshot.schemaVersion - 1
            let staleData = try JSONSerialization.data(withJSONObject: object)
            try staleData.write(to: cacheURL, options: .atomic)

            let loaded = await cache.loadSnapshot()

            XCTAssertNil(loaded)
        }
    }

    func testCachedGroupRehydrationForcesManualReview() {
        let keeper = PHAsset()
        let deleteCandidate = PHAsset()
        let keeperID = "cached-keeper"
        let deleteCandidateID = "cached-delete-candidate"
        let cachedGroup = CachedPhotoGroup(
            id: UUID(),
            assetIdentifiers: [keeperID, deleteCandidateID],
            similarity: 0.01,
            reason: .nearDuplicate,
            groupType: .nearDuplicate,
            groupConfidence: .high,
            reviewState: .unreviewed,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: keeperID,
            deleteCandidateIDs: [deleteCandidateID],
            bestShotPhotoId: keeperID,
            groupReasonsSummary: ["Previously classified as a near duplicate."],
            reclaimableBytes: 4_096
        )

        let rehydrated = cachedGroup.makeGroup(
            using: [
                keeperID: keeper,
                deleteCandidateID: deleteCandidate
            ]
        )

        XCTAssertEqual(rehydrated?.recommendedAction, .reviewManually)
        XCTAssertEqual(rehydrated?.deleteCandidateIDs, [])
        XCTAssertEqual(rehydrated?.reclaimableBytes, 0)
        XCTAssertFalse(rehydrated?.isAutoCleanEligible ?? true)
        XCTAssertTrue(
            rehydrated?.groupReasonsSummary.contains(
                "Cached result requires live revalidation."
            ) == true
        )
    }

    func testCompleteLinkPreventsChaining() {
        let descriptors = [
            descriptor("A", seconds: 0),
            descriptor("B", seconds: 1),
            descriptor("C", seconds: 2)
        ]
        let pairs = [
            SimilarityPairKey("A", "B"): eligible(score: 0.90),
            SimilarityPairKey("B", "C"): eligible(score: 0.80)
        ]

        let clusters = graph.formClusters(descriptors: descriptors, pairResults: pairs)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0]), Set(["A", "B"]))
        XCTAssertFalse(clusters[0].contains("C"))
    }

    func testCompleteLinkAllowsConsistentTriple() {
        let descriptors = [
            descriptor("A", seconds: 0),
            descriptor("B", seconds: 1),
            descriptor("C", seconds: 2)
        ]
        let pairs = [
            SimilarityPairKey("A", "B"): eligible(score: 0.90),
            SimilarityPairKey("A", "C"): eligible(score: 0.82),
            SimilarityPairKey("B", "C"): eligible(score: 0.85)
        ]

        let clusters = graph.formClusters(descriptors: descriptors, pairResults: pairs)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0]), Set(["A", "B", "C"]))
    }

    func testOverlappingEvidenceProducesDisjointGroups() {
        let descriptors = [
            descriptor("A", seconds: 0),
            descriptor("B", seconds: 1),
            descriptor("C", seconds: 2),
            descriptor("D", seconds: 3)
        ]
        let pairs = [
            SimilarityPairKey("A", "B"): eligible(score: 0.95),
            SimilarityPairKey("B", "C"): eligible(score: 0.75),
            SimilarityPairKey("C", "D"): eligible(score: 0.90)
        ]

        let clusters = graph.formClusters(descriptors: descriptors, pairResults: pairs)
        let flattened = clusters.flatMap { $0 }

        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(Set(flattened).count, flattened.count)
        XCTAssertEqual(Set(clusters.map(Set.init)), Set([Set(["A", "B"]), Set(["C", "D"])]))
    }

    func testBurstMembershipCreatesReviewGroupWithoutVisualEvidence() {
        let descriptors = [
            descriptor("A", seconds: 0, burst: "burst"),
            descriptor("B", seconds: 1, burst: "burst"),
            descriptor("C", seconds: 2, burst: "burst")
        ]

        let clusters = graph.formClusters(descriptors: descriptors, pairResults: [:])

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0]), Set(["A", "B", "C"]))
    }

    func testBurstChunkBoundariesKeepEveryAssetReviewable() {
        let expectedChunkSizes = [
            40: [40],
            41: [39, 2],
            80: [40, 40],
            81: [40, 39, 2]
        ]

        for (assetCount, expectedSizes) in expectedChunkSizes {
            let descriptors = (0..<assetCount).map {
                descriptor(
                    String(format: "%03d", $0),
                    seconds: TimeInterval($0),
                    burst: "burst"
                )
            }

            let clusters = graph.formClusters(
                descriptors: descriptors,
                pairResults: [:]
            )
            let memberIDs = clusters.flatMap { $0 }

            XCTAssertEqual(
                clusters.map(\.count),
                expectedSizes,
                "Unexpected burst chunks for \(assetCount) assets"
            )
            XCTAssertEqual(memberIDs.count, assetCount)
            XCTAssertEqual(Set(memberIDs).count, assetCount)
            XCTAssertTrue(clusters.allSatisfy { $0.count >= 2 })
        }
    }

    func testGroupCacheKeyIgnoresMemberOrderButNotMembership() {
        XCTAssertEqual(
            PhotoScanGroupCacheKey(memberIDs: ["C", "A", "B"]),
            PhotoScanGroupCacheKey(memberIDs: ["B", "C", "A"])
        )
        XCTAssertNotEqual(
            PhotoScanGroupCacheKey(memberIDs: ["A", "B"]),
            PhotoScanGroupCacheKey(memberIDs: ["A", "B", "C"])
        )
        XCTAssertNotEqual(
            PhotoScanGroupCacheKey(memberIDs: ["A", "A", "B"]),
            PhotoScanGroupCacheKey(memberIDs: ["A", "B"])
        )
    }

    private func descriptor(
        _ id: String,
        seconds: TimeInterval,
        burst: String? = nil
    ) -> SimilarityAssetDescriptor {
        SimilarityAssetDescriptor(
            id: id,
            captureTimestamp: Date(timeIntervalSinceReferenceDate: seconds),
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            burstIdentifier: burst
        )
    }

    private func eligible(
        score: Double,
        bucket: SimilarityBucket = .nearDuplicate
    ) -> PairEligibilityResult {
        PairEligibilityResult(
            eligible: true,
            provisionalBucket: bucket,
            hardBlockers: [],
            softBlockers: [],
            similarityScore: score,
            reasonStrings: []
        )
    }

    private func makeAnalysisSnapshot(
        analyzedPhotoCount: Int,
        unanalyzedPhotoCount: Int
    ) -> CachedPhotoAnalysisSnapshot {
        CachedPhotoAnalysisSnapshot(
            savedAt: Date(timeIntervalSinceReferenceDate: 123),
            libraryTotalCount: 12,
            scanTargetCount: 10,
            processedPhotoCount: analyzedPhotoCount + unanalyzedPhotoCount,
            analyzedPhotoCount: analyzedPhotoCount,
            unanalyzedPhotoCount: unanalyzedPhotoCount,
            progressFraction: 1,
            groupsFoundCount: 0,
            reviewablePhotosCount: 0,
            reclaimableBytesFoundSoFar: 0,
            cleanupMode: .deepClean,
            resultsFreshnessState: .live,
            groups: []
        )
    }

    private func withIsolatedAnalysisCacheFile(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent(
            "PhotoDuck",
            isDirectory: true
        )
        let cacheURL = directoryURL.appendingPathComponent(
            "photo-analysis-cache.json"
        )
        let originalData = try? Data(contentsOf: cacheURL)

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: cacheURL)
        defer {
            if let originalData {
                try? originalData.write(to: cacheURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: cacheURL)
            }
        }

        try await operation(cacheURL)
    }

    private enum VisionFixtureStyle {
        case reference
        case unrelated
    }

    private func makeVisionFixture(style: VisionFixtureStyle) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 256, height: 256),
            format: format
        )

        let image = renderer.image { context in
            switch style {
            case .reference:
                UIColor(red: 0.32, green: 0.70, blue: 0.92, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 256, height: 150))
                UIColor(red: 0.18, green: 0.52, blue: 0.24, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 150, width: 256, height: 106))
                UIColor(red: 0.98, green: 0.76, blue: 0.18, alpha: 1).setFill()
                context.cgContext.fillEllipse(
                    in: CGRect(x: 168, y: 24, width: 52, height: 52)
                )
                UIColor(red: 0.45, green: 0.24, blue: 0.12, alpha: 1).setFill()
                context.fill(CGRect(x: 55, y: 104, width: 20, height: 94))
                UIColor(red: 0.10, green: 0.38, blue: 0.16, alpha: 1).setFill()
                context.cgContext.fillEllipse(
                    in: CGRect(x: 20, y: 66, width: 92, height: 92)
                )

            case .unrelated:
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                for index in 0..<8 {
                    let color = index.isMultiple(of: 2)
                        ? UIColor.white
                        : UIColor(red: 0.92, green: 0.12, blue: 0.18, alpha: 1)
                    color.setFill()
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: 128, y: 128)
                    context.cgContext.rotate(by: .pi / 4)
                    context.fill(
                        CGRect(
                            x: -220 + CGFloat(index * 56),
                            y: -220,
                            width: 24,
                            height: 440
                        )
                    )
                    context.cgContext.restoreGState()
                }
            }
        }

        return image.cgImage!
    }

    private func featurePrintObservation(
        for image: CGImage
    ) throws -> VNFeaturePrintObservation {
        let request = PhotoMLBridge.makePinnedFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return try XCTUnwrap(request.results?.first as? VNFeaturePrintObservation)
    }
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}

private struct StubPhotoScanAssetProvider: PhotoScanAssetProviding, @unchecked Sendable {
    let assets: [PHAsset]

    func fetchImageAssets() async throws -> [PHAsset] {
        assets
    }
}

private final class PhotoScanTestAsset: PHAsset, @unchecked Sendable {
    private let testLocalIdentifier: String
    private let testCreationDate: Date

    init(localIdentifier: String, creationDate: Date) {
        testLocalIdentifier = localIdentifier
        testCreationDate = creationDate
        super.init()
    }

    override var localIdentifier: String {
        testLocalIdentifier
    }

    override var creationDate: Date? {
        testCreationDate
    }

    override var pixelWidth: Int {
        4_032
    }

    override var pixelHeight: Int {
        3_024
    }

    override var mediaType: PHAssetMediaType {
        .image
    }
}

private actor ScanAnalyzerProbe {
    private(set) var startedCount = 0
    private(set) var cancelledCount = 0

    func analyze() async -> PhotoScanAssetAnalysis {
        startedCount += 1
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } catch {
            cancelledCount += 1
        }
        return .unavailable
    }
}
