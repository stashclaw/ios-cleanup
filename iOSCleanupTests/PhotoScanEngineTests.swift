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
        let normalizedRepeatedDistance = try XCTUnwrap(
            PhotoFeatureDistanceNormalizer.normalizedDistance(
                rawDistance: Double(repeatedDistance),
                elementCount: matchingObservation.elementCount
            )
        )
        let normalizedUnrelatedDistance = try XCTUnwrap(
            PhotoFeatureDistanceNormalizer.normalizedDistance(
                rawDistance: Double(unrelatedDistance),
                elementCount: matchingObservation.elementCount
            )
        )

        XCTAssertEqual(
            matchingObservation.elementCount,
            PhotoEmbeddingContract.elementCount
        )
        XCTAssertEqual(
            matchingObservation.data.count,
            PhotoEmbeddingContract.byteCount
        )
        XCTAssertLessThanOrEqual(normalizedRepeatedDistance, 0.001)
        XCTAssertGreaterThan(
            normalizedUnrelatedDistance,
            SimilarityThresholds.maxVisualSimilarFeatureDistance
        )
    }

    func testFeatureDistanceNormalizerUsesRMSScale() throws {
        let expectedDistance = 0.16
        let rawDistance = sqrt(Double(PhotoEmbeddingContract.elementCount))
            * expectedDistance

        let normalizedDistance = try XCTUnwrap(
            PhotoFeatureDistanceNormalizer.normalizedDistance(
                rawDistance: rawDistance,
                elementCount: PhotoEmbeddingContract.elementCount
            )
        )

        XCTAssertEqual(normalizedDistance, expectedDistance, accuracy: 0.000_001)
        XCTAssertNil(
            PhotoFeatureDistanceNormalizer.normalizedDistance(
                rawDistance: -1,
                elementCount: PhotoEmbeddingContract.elementCount
            )
        )
        XCTAssertNil(
            PhotoFeatureDistanceNormalizer.normalizedDistance(
                rawDistance: rawDistance,
                elementCount: 0
            )
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

    func testPairDistanceResolverRejectsLegacyRawDistanceVersion() {
        let key = SimilarityPairKey("left", "right")
        let cachedRecord = PairSimilarityRecord(
            lhsAssetID: "left",
            rhsAssetID: "right",
            embeddingVersion: PhotoEmbeddingContract.legacyEmbeddingVersion,
            featureDistance: 5.2,
            timeDeltaSeconds: 1,
            isBurstPair: false,
            bucket: SimilarityBucket.visuallySimilar.rawValue,
            similarityScore: 0.8
        )

        XCTAssertNil(
            PhotoScanPairDistanceResolver.cachedResolution(
                key: key,
                cachedRecords: [key: cachedRecord]
            )
        )
    }

    func testTuningConstantsStayPrecisionFirstAndBounded() {
        XCTAssertFalse(PhotoScanDefaults.allowNetworkAccess)
        XCTAssertLessThan(
            SimilarityThresholds.maxNearDuplicateFeatureDistance,
            SimilarityThresholds.maxVisualSimilarFeatureDistance
        )
        XCTAssertLessThan(
            SimilarityThresholds.maxExtendedVisualFeatureDistance,
            SimilarityThresholds.maxVisualSimilarFeatureDistance
        )
        XCTAssertGreaterThan(
            SimilarityThresholds.featureScoreNormalizationDistance,
            SimilarityThresholds.maxVisualSimilarFeatureDistance
        )
        XCTAssertLessThanOrEqual(
            SimilarityThresholds.maxFeatureComparisonsPerAsset,
            SimilarityThresholds.maxCandidateAssetsInspected
        )
        XCTAssertLessThanOrEqual(
            SimilarityThresholds.reservedExtendedFeatureComparisonsPerAsset,
            SimilarityThresholds.maxFeatureComparisonsPerAsset
        )
        XCTAssertLessThanOrEqual(
            SimilarityThresholds.maxRetainedGenericPairEdgesPerAsset,
            SimilarityThresholds.maxFeatureComparisonsPerAsset
        )
        XCTAssertLessThan(
            SimilarityThresholds.nearDuplicateWindowSeconds,
            SimilarityThresholds.visualSessionWindowSeconds
        )
        XCTAssertLessThan(
            SimilarityThresholds.visualSessionWindowSeconds,
            SimilarityThresholds.extendedVisualSessionWindowSeconds
        )
        XCTAssertLessThanOrEqual(
            SimilarityThresholds.visualReviewClusterFloor,
            SimilarityThresholds.visualClusterFloor
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
            screenshotAssets: [],
            blurryAssets: [],
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

    func testScreenshotCategoryTakesPriorityOverBlurSignal() {
        XCTAssertEqual(
            PhotoReviewCategoryClassifier.classify(
                isScreenshot: true,
                sharpness: 0
            ),
            .screenshot
        )
    }

    func testBlurryCategoryUsesConservativeTuningBoundary() {
        XCTAssertEqual(
            PhotoReviewCategoryClassifier.classify(
                isScreenshot: false,
                sharpness: PhotoScanDefaults.blurryPhotoSharpnessCeiling
            ),
            .blurry
        )
        XCTAssertNil(
            PhotoReviewCategoryClassifier.classify(
                isScreenshot: false,
                sharpness: PhotoScanDefaults.blurryPhotoSharpnessCeiling + 0.001
            )
        )
        XCTAssertNil(
            PhotoReviewCategoryClassifier.classify(
                isScreenshot: false,
                sharpness: nil
            )
        )
    }

    func testReviewableCountDoesNotDoubleCountCategoryAssetsInGroups() {
        let first = PhotoScanTestAsset(
            localIdentifier: "group-first",
            creationDate: Date(timeIntervalSinceReferenceDate: 0)
        )
        let second = PhotoScanTestAsset(
            localIdentifier: "group-second",
            creationDate: Date(timeIntervalSinceReferenceDate: 1)
        )
        let categoryOnly = PhotoScanTestAsset(
            localIdentifier: "category-only",
            creationDate: Date(timeIntervalSinceReferenceDate: 2)
        )
        let group = PhotoGroup(
            assets: [first, second],
            similarity: 0.1,
            reason: .visuallySimilar,
            recommendedAction: .reviewManually
        )

        XCTAssertEqual(
            PhotoReviewCategoryClassifier.reviewableCount(
                groups: [group],
                screenshotAssets: [first],
                blurryAssets: [categoryOnly, categoryOnly]
            ),
            2
        )
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

    func testIncrementalScanWithUnchangedInventoryPerformsNoAnalysis() async throws {
        let asset = PhotoScanTestAsset(
            localIdentifier: "existing",
            creationDate: Date(timeIntervalSinceReferenceDate: 1)
        )
        let invocationCounter = LockedInvocationCounter()
        let engine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(assets: [asset]),
            assetAnalyzer: { _, _ in
                invocationCounter.increment()
                return .unavailable
            }
        )

        var finalUpdate: PhotoScanUpdate?
        for try await update in engine.scan(
            mode: .deepClean,
            requiredAssetIDs: []
        ) {
            finalUpdate = update
        }

        XCTAssertEqual(invocationCounter.value, 0)
        XCTAssertEqual(finalUpdate?.scanTargetCount, 0)
        XCTAssertEqual(finalUpdate?.evaluatedAssetIDs, [])
        XCTAssertTrue(finalUpdate?.isComplete == true)
    }

    func testIncrementalScanAnalyzesNewAssetAndBoundedSessionContext() async throws {
        let farAsset = PhotoScanTestAsset(
            localIdentifier: "far",
            creationDate: Date(timeIntervalSinceReferenceDate: 0)
        )
        let nearbyAsset = PhotoScanTestAsset(
            localIdentifier: "nearby",
            creationDate: Date(timeIntervalSinceReferenceDate: 10_000)
        )
        let newAsset = PhotoScanTestAsset(
            localIdentifier: "new",
            creationDate: Date(timeIntervalSinceReferenceDate: 10_001)
        )
        let engine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(
                assets: [farAsset, nearbyAsset, newAsset]
            ),
            assetAnalyzer: { _, _ in .unavailable }
        )

        var finalUpdate: PhotoScanUpdate?
        for try await update in engine.scan(
            mode: .deepClean,
            requiredAssetIDs: ["new"]
        ) {
            if update.isComplete {
                finalUpdate = update
            }
        }

        XCTAssertEqual(
            finalUpdate?.evaluatedAssetIDs,
            ["nearby", "new"]
        )
        XCTAssertEqual(finalUpdate?.processedPhotoCount, 2)
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

    func testAnalysisCacheCurrentSchemaRoundTripPreservesCoverageCounts() async throws {
        try await withIsolatedAnalysisCacheFile { _ in
            let cache = PhotoAnalysisCache()
            let snapshot = makeAnalysisSnapshot(
                analyzedPhotoCount: 7,
                unanalyzedPhotoCount: 3,
                screenshotAssetIdentifiers: ["screen-1"],
                blurryAssetIdentifiers: ["blur-1"]
            )

            await cache.saveSnapshot(snapshot)
            let loaded = await cache.loadSnapshot()

            XCTAssertEqual(
                loaded?.schemaVersion,
                CachedPhotoAnalysisSnapshot.schemaVersion
            )
            XCTAssertEqual(loaded?.processedPhotoCount, 10)
            XCTAssertEqual(loaded?.analyzedPhotoCount, 7)
            XCTAssertEqual(loaded?.unanalyzedPhotoCount, 3)
            XCTAssertEqual(loaded?.cleanupMode, .deepClean)
            XCTAssertEqual(loaded?.screenshotAssetIdentifiers, ["screen-1"])
            XCTAssertEqual(loaded?.blurryAssetIdentifiers, ["blur-1"])
            XCTAssertEqual(
                loaded?.libraryAssetIdentifiers,
                ["library-1", "library-2"]
            )
            XCTAssertEqual(loaded?.libraryAssets.count, 2)
        }
    }

    func testCleanupStatsStorePersistsConfirmedTotalsAndClampsOverflow() {
        let suiteName = "CleanupStatsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CleanupStatsStore(defaults: defaults)

        XCTAssertEqual(
            store.recordConfirmedDeletion(bytes: 4_096, itemCount: 2),
            CleanupStats(lifetimeBytesFreed: 4_096, lifetimeItemsFreed: 2)
        )
        XCTAssertEqual(
            CleanupStatsStore(defaults: defaults).load(),
            CleanupStats(lifetimeBytesFreed: 4_096, lifetimeItemsFreed: 2)
        )

        _ = store.recordConfirmedDeletion(bytes: .max, itemCount: .max)
        let clamped = store.recordConfirmedDeletion(bytes: 1, itemCount: 1)
        XCTAssertEqual(clamped.lifetimeBytesFreed, .max)
        XCTAssertEqual(clamped.lifetimeItemsFreed, .max)
    }

    func testCleanupStatsStoreIgnoresNegativeDeltas() {
        let suiteName = "CleanupStatsStoreNegativeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CleanupStatsStore(defaults: defaults)

        let stats = store.recordConfirmedDeletion(bytes: -100, itemCount: -2)

        XCTAssertEqual(stats, CleanupStats())
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

    func testCompleteCachedGroupRehydrationPreservesValidatedAction() {
        let keeperID = "cached-keeper"
        let deleteCandidateID = "cached-delete-candidate"
        let keeper = PhotoScanTestAsset(
            localIdentifier: keeperID,
            creationDate: Date(timeIntervalSinceReferenceDate: 1)
        )
        let deleteCandidate = PhotoScanTestAsset(
            localIdentifier: deleteCandidateID,
            creationDate: Date(timeIntervalSinceReferenceDate: 2)
        )
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

        XCTAssertEqual(rehydrated?.recommendedAction, .keepBestTrashRest)
        XCTAssertEqual(rehydrated?.deleteCandidateIDs, [deleteCandidateID])
        XCTAssertEqual(rehydrated?.reclaimableBytes, 4_096)
        XCTAssertTrue(rehydrated?.isAutoCleanEligible == true)
    }

    func testIncompleteCachedGroupRehydrationForcesManualReview() {
        let keeperID = "cached-keeper"
        let survivingCandidateID = "cached-survivor"
        let missingCandidateID = "cached-missing"
        let keeper = PhotoScanTestAsset(
            localIdentifier: keeperID,
            creationDate: Date(timeIntervalSinceReferenceDate: 1)
        )
        let survivingCandidate = PhotoScanTestAsset(
            localIdentifier: survivingCandidateID,
            creationDate: Date(timeIntervalSinceReferenceDate: 2)
        )
        let cachedGroup = CachedPhotoGroup(
            id: UUID(),
            assetIdentifiers: [
                keeperID,
                survivingCandidateID,
                missingCandidateID
            ],
            similarity: 0.01,
            reason: .nearDuplicate,
            groupType: .nearDuplicate,
            groupConfidence: .high,
            reviewState: .unreviewed,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: keeperID,
            deleteCandidateIDs: [
                survivingCandidateID,
                missingCandidateID
            ],
            bestShotPhotoId: keeperID,
            groupReasonsSummary: ["Previously classified as a near duplicate."],
            reclaimableBytes: 8_192
        )

        let rehydrated = cachedGroup.makeGroup(
            using: [
                keeperID: keeper,
                survivingCandidateID: survivingCandidate
            ]
        )

        XCTAssertEqual(rehydrated?.recommendedAction, .reviewManually)
        XCTAssertEqual(rehydrated?.deleteCandidateIDs, [])
        XCTAssertEqual(rehydrated?.reclaimableBytes, 0)
        XCTAssertFalse(rehydrated?.isAutoCleanEligible ?? true)
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

    func testCandidateSelectorReservesExtendedWindowCoverage() {
        let current = descriptor("current", seconds: 4_000)
        let primary = (0..<140).map {
            descriptor(
                "primary-\($0)",
                seconds: 3_999 - TimeInterval($0)
            )
        }
        let extended = (0..<30).map {
            descriptor(
                "extended-\($0)",
                seconds: 1_900 - TimeInterval($0)
            )
        }
        let tooOld = descriptor("too-old", seconds: 0)
        let allDescriptors = ([tooOld] + extended + primary).sorted {
            ($0.captureTimestamp ?? .distantPast)
                < ($1.captureTimestamp ?? .distantPast)
        }
        let descriptorsByID = Dictionary(
            uniqueKeysWithValues: allDescriptors.map { ($0.id, $0) }
        )

        let candidateIDs = PhotoScanCandidateSelector.genericCandidateIDs(
            for: current,
            orderedProcessedIDs: allDescriptors.map(\.id),
            descriptorsByID: descriptorsByID
        )

        XCTAssertEqual(
            candidateIDs.count,
            SimilarityThresholds.maxFeatureComparisonsPerAsset
        )
        XCTAssertEqual(
            candidateIDs.filter { $0.hasPrefix("extended-") }.count,
            SimilarityThresholds.reservedExtendedFeatureComparisonsPerAsset
        )
        XCTAssertEqual(
            candidateIDs.filter { $0.hasPrefix("primary-") }.count,
            SimilarityThresholds.maxFeatureComparisonsPerAsset
                - SimilarityThresholds.reservedExtendedFeatureComparisonsPerAsset
        )
        XCTAssertFalse(candidateIDs.contains("too-old"))
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
        unanalyzedPhotoCount: Int,
        screenshotAssetIdentifiers: [String] = [],
        blurryAssetIdentifiers: [String] = []
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
            groups: [],
            screenshotAssetIdentifiers: screenshotAssetIdentifiers,
            blurryAssetIdentifiers: blurryAssetIdentifiers,
            libraryAssetIdentifiers: ["library-1", "library-2"],
            libraryAssets: [
                CachedPhotoAssetMetadata(
                    localIdentifier: "library-1",
                    modificationDate: nil,
                    pixelWidth: 4_032,
                    pixelHeight: 3_024,
                    mediaSubtypesRawValue: 0
                ),
                CachedPhotoAssetMetadata(
                    localIdentifier: "library-2",
                    modificationDate: Date(timeIntervalSinceReferenceDate: 2),
                    pixelWidth: 4_032,
                    pixelHeight: 3_024,
                    mediaSubtypesRawValue: 0
                )
            ]
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
