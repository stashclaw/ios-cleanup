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

    func testStoredEmbeddingValueDistanceMatchesNormalizedRMSContract() throws {
        let lhsValues = [Float](
            repeating: 0,
            count: PhotoEmbeddingContract.elementCount
        )
        let rhsValues = [Float](
            repeating: 0.25,
            count: PhotoEmbeddingContract.elementCount
        )
        let lhs = lhsValues.withUnsafeBytes { Data($0) }
        let rhs = rhsValues.withUnsafeBytes { Data($0) }

        XCTAssertEqual(
            try XCTUnwrap(
                PhotoEmbeddingValueDistance.normalizedDistance(
                    lhs: lhs,
                    rhs: rhs
                )
            ),
            0.25,
            accuracy: 0.000_001
        )
        XCTAssertNil(
            PhotoEmbeddingValueDistance.normalizedDistance(
                lhs: Data(),
                rhs: rhs
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

    func testPhotoAssetIdentityRemovesRepeatedPhotoKitAssetsInOrder() {
        let first = PhotoScanTestAsset(
            localIdentifier: "first",
            creationDate: Date(timeIntervalSinceReferenceDate: 1)
        )
        let repeatedFirst = PhotoScanTestAsset(
            localIdentifier: "first",
            creationDate: Date(timeIntervalSinceReferenceDate: 2)
        )
        let second = PhotoScanTestAsset(
            localIdentifier: "second",
            creationDate: Date(timeIntervalSinceReferenceDate: 3)
        )

        let unique = PhotoAssetIdentity.unique(
            [first, repeatedFirst, second, first]
        )

        XCTAssertEqual(
            unique.map(\.localIdentifier),
            ["first", "second"]
        )
        XCTAssertTrue(unique[0] === first)
    }

    func testTuningConstantsStayPrecisionFirstAndBounded() {
        XCTAssertEqual(PhotoScanDefaults.analysisBatchSize, 8)
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

    func testExpectedNonemptyLibraryCannotCompleteAsZeroPhotos() async {
        let engine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(assets: [])
        )

        do {
            for try await _ in engine.scan(
                mode: .deepClean,
                expectedLibraryPhotoCount: 48_680
            ) {
                XCTFail("A transient empty fetch must not publish completion")
            }
            XCTFail("Expected an unavailable-library error")
        } catch let error as ScanError {
            guard case .photoLibraryTemporarilyUnavailable(
                expectedCount: 48_680,
                receivedCount: 0
            ) = error else {
                return XCTFail("Unexpected scan error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExpectedLibraryRejectsTruncatedNonemptyFetch() async {
        let assets = (0..<3).map {
            PhotoScanTestAsset(
                localIdentifier: "partial-\($0)",
                creationDate: Date(
                    timeIntervalSinceReferenceDate: TimeInterval($0)
                )
            )
        }
        let engine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(assets: assets)
        )

        do {
            for try await _ in engine.scan(
                mode: .deepClean,
                expectedLibraryPhotoCount: 48_680
            ) {
                XCTFail("A truncated fetch must not publish completion")
            }
            XCTFail("Expected an unavailable-library error")
        } catch let error as ScanError {
            guard case .photoLibraryTemporarilyUnavailable(
                expectedCount: 48_680,
                receivedCount: 3
            ) = error else {
                return XCTFail("Unexpected scan error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAnalysisWatchdogBoundsHungOperations() async {
        let gate = PhotoScanTestGate()
        let invocationCounter = LockedInvocationCounter()
        let coordinator = PhotoScanAnalysisCoordinator(
            maximumConcurrentOperationCount: 1,
            timeoutNanoseconds: 50_000_000
        )

        let first = await coordinator.analyze {
            invocationCounter.increment()
            await gate.wait()
            return PhotoScanAssetAnalysis(
                observation: nil,
                embedding: Data([1]),
                perceptualHash: nil,
                keeperSignals: nil
            )
        }
        let second = await coordinator.analyze {
            invocationCounter.increment()
            return PhotoScanAssetAnalysis(
                observation: nil,
                embedding: Data([2]),
                perceptualHash: nil,
                keeperSignals: nil
            )
        }

        // The watchdog bounds the hung operation…
        XCTAssertNil(first.embedding)
        // …and hands its slot back. Previously the timeout resolved the caller
        // but kept the slot forever, so one hung asset permanently starved the
        // coordinator and every later analyze() returned `.unavailable`
        // without ever running — which silently defeated the iCloud retry pass.
        XCTAssertEqual(second.embedding, Data([2]))
        XCTAssertEqual(invocationCounter.value, 2)
        await gate.open()
    }

    func testTimedOutSlotIsReleasedExactlyOnceWhenOperationLaterCompletes() async {
        let gate = PhotoScanTestGate()
        let coordinator = PhotoScanAnalysisCoordinator(
            maximumConcurrentOperationCount: 1,
            timeoutNanoseconds: 50_000_000
        )

        // Times out, then the underlying operation finishes afterwards. Both
        // paths must not double-release the single slot.
        let timedOut = await coordinator.analyze {
            await gate.wait()
            return PhotoScanAssetAnalysis(
                observation: nil,
                embedding: Data([1]),
                perceptualHash: nil,
                keeperSignals: nil
            )
        }
        XCTAssertNil(timedOut.embedding)
        await gate.open()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // A double release would let two operations run concurrently against a
        // coordinator declared with a maximum of one.
        let follower = await coordinator.analyze {
            PhotoScanAssetAnalysis(
                observation: nil,
                embedding: Data([2]),
                perceptualHash: nil,
                keeperSignals: nil
            )
        }
        XCTAssertEqual(follower.embedding, Data([2]))

        let blockedGate = PhotoScanTestGate()
        async let blocking = coordinator.analyze {
            await blockedGate.wait()
            return PhotoScanAssetAnalysis(
                observation: nil,
                embedding: Data([3]),
                perceptualHash: nil,
                keeperSignals: nil
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let rejected = await coordinator.analyze {
            PhotoScanAssetAnalysis(
                observation: nil,
                embedding: Data([4]),
                perceptualHash: nil,
                keeperSignals: nil
            )
        }
        XCTAssertNil(rejected.embedding)
        await blockedGate.open()
        _ = await blocking
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

    func testWarmIncrementalScanReusesUnchangedContextAnalysis() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WarmAnalysisCacheTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let bridge = PhotoMLBridge(
            store: PhotoMLStore(directoryURL: tempDirectory)
        )
        let existing = PhotoScanTestAsset(
            localIdentifier: "warm-existing",
            creationDate: Date(timeIntervalSinceReferenceDate: 10_000)
        )
        let added = PhotoScanTestAsset(
            localIdentifier: "warm-added",
            creationDate: Date(timeIntervalSinceReferenceDate: 10_001)
        )
        let invocationCounter = LockedInvocationCounter()
        let embeddingValues = [Float](
            repeating: 0.5,
            count: PhotoEmbeddingContract.elementCount
        )
        let embedding = embeddingValues.withUnsafeBytes { Data($0) }
        let keeperSignals = KeeperSignals(
            sharpness: 0.8,
            blurPenalty: 0.1,
            motionBlurPenalty: 0.05,
            eyesOpenScore: nil,
            expressionScore: nil,
            exposureScore: 0.9,
            favoriteBonus: 0,
            editedBonusOrPenalty: 0,
            framingScore: 0.8,
            resolutionTiebreaker: 0.1
        )
        let analyzer: PhotoScanAssetAnalyzer = { _, _ in
            invocationCounter.increment()
            return PhotoScanAssetAnalysis(
                observation: nil,
                embedding: embedding,
                perceptualHash: 0x1234,
                keeperSignals: keeperSignals
            )
        }

        let initialEngine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(assets: [existing]),
            assetAnalyzer: analyzer,
            mlBridge: bridge
        )
        for try await _ in initialEngine.scan(mode: .deepClean) {}

        let incrementalEngine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(
                assets: [existing, added]
            ),
            assetAnalyzer: analyzer,
            mlBridge: bridge
        )
        var finalUpdate: PhotoScanUpdate?
        for try await update in incrementalEngine.scan(
            mode: .deepClean,
            requiredAssetIDs: [added.localIdentifier]
        ) {
            if update.isComplete { finalUpdate = update }
        }

        XCTAssertEqual(invocationCounter.value, 2)
        XCTAssertEqual(finalUpdate?.evaluatedAssetIDs, [added.localIdentifier])
        XCTAssertEqual(finalUpdate?.processedPhotoCount, 1)
    }

    func testBufferedProgressCarriesDurableCheckpointIntoResumePlan() async throws {
        let assets = (0..<12).map {
            PhotoScanTestAsset(
                localIdentifier: "resume-\($0)",
                creationDate: Date(
                    timeIntervalSinceReferenceDate: TimeInterval($0 * 10_000)
                )
            )
        }
        let engine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(assets: assets),
            assetAnalyzer: { _, _ in
                try? await Task.sleep(nanoseconds: 5_000_000)
                return .unavailable
            }
        )

        var checkpointUpdate: PhotoScanUpdate?
        for try await update in engine.scan(mode: .deepClean) {
            if !update.isComplete,
               let committedCount = update.committedProcessedPhotoCount,
               committedCount >= 4 {
                checkpointUpdate = update
                break
            }
        }

        let update = try XCTUnwrap(checkpointUpdate)
        let committedCount = try XCTUnwrap(update.committedProcessedPhotoCount)
        XCTAssertEqual(committedCount, update.evaluatedAssetIDs.count)

        let allIDs = Set(assets.map(\.localIdentifier))
        let metadata = makeLibraryMetadata(ids: Array(allIDs))
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: update.committedAnalyzedPhotoCount ?? 0,
            unanalyzedPhotoCount: update.committedUnanalyzedPhotoCount ?? 0,
            isComplete: false,
            evaluatedAssetIdentifiers: Array(update.evaluatedAssetIDs),
            scanTargetAssetIdentifiers: Array(update.targetAssetIDs),
            libraryMetadata: metadata
        )

        let required = try XCTUnwrap(
            PhotoScanResumePlanner.requiredAssetIDs(
                snapshot: snapshot,
                currentAssetIDs: allIDs,
                currentMetadata: metadata,
                mode: .deepClean,
                forceFullRescan: false
            )
        )

        XCTAssertTrue(required.isDisjoint(with: update.evaluatedAssetIDs))
        XCTAssertEqual(required, allIDs.subtracting(update.evaluatedAssetIDs))
    }

    func testScanUpdateCountIsBoundedByBatchCount() async throws {
        let assets = (0..<25).map {
            PhotoScanTestAsset(
                localIdentifier: "bounded-update-\($0)",
                creationDate: Date(timeIntervalSinceReferenceDate: TimeInterval($0))
            )
        }
        let engine = PhotoScanEngine(
            assetProvider: StubPhotoScanAssetProvider(assets: assets),
            assetAnalyzer: { _, _ in .unavailable }
        )

        var updateCount = 0
        for try await _ in engine.scan(mode: .deepClean) {
            updateCount += 1
        }

        let committedBatchCount = Int(
            ceil(Double(assets.count) / Double(PhotoScanDefaults.analysisBatchSize))
        )
        print(
            "PERF scan_updates assets=\(assets.count) updates=\(updateCount) batches=\(committedBatchCount)"
        )
        XCTAssertLessThanOrEqual(updateCount, committedBatchCount + 1)
        XCTAssertLessThan(updateCount, assets.count)
    }

    func testCheckpointWritesCoalesceAndNeverEncodeConcurrently() async throws {
        try await withIsolatedAnalysisCacheFile { _ in
            let cache = PhotoAnalysisCache()
            for count in 0..<20 {
                let snapshot = makeAnalysisSnapshot(
                    analyzedPhotoCount: min(count, 10),
                    unanalyzedPhotoCount: 0,
                    isComplete: false
                )
                await cache.scheduleSnapshot(snapshot)
            }
            let newest = makeAnalysisSnapshot(
                analyzedPhotoCount: 10,
                unanalyzedPhotoCount: 0
            )
            await cache.saveSnapshot(newest)

            let loaded = await cache.loadSnapshot()
            let maximumActive = await cache.maximumObservedActiveEncodeCount
            let writeCount = await cache.completedWriteCount
            let durationMilliseconds = await cache.lastEncodeWriteDuration * 1_000
            let encodedByteCount = await cache.lastEncodedByteCount
            print(
                "PERF checkpoint_coalescing requests=21 writes=\(writeCount) max_active=\(maximumActive) last_bytes=\(encodedByteCount) last_ms=\(durationMilliseconds)"
            )
            XCTAssertEqual(maximumActive, 1)
            XCTAssertLessThan(writeCount, 20)
            XCTAssertEqual(loaded?.analyzedPhotoCount, 10)
            XCTAssertGreaterThan(loaded?.persistenceGeneration ?? 0, 0)
        }
    }

    func testExplicitStaleGenerationCannotReplaceNewerSnapshot() async throws {
        try await withIsolatedAnalysisCacheFile { _ in
            let cache = PhotoAnalysisCache()
            let newer = makeAnalysisSnapshot(
                analyzedPhotoCount: 9,
                unanalyzedPhotoCount: 1
            ).withPersistenceGeneration(20)
            let stale = makeAnalysisSnapshot(
                analyzedPhotoCount: 2,
                unanalyzedPhotoCount: 8
            ).withPersistenceGeneration(19)

            await cache.saveSnapshot(newer)
            await cache.saveSnapshot(stale)

            let loaded = await cache.loadSnapshot()
            XCTAssertEqual(loaded?.persistenceGeneration, 20)
            XCTAssertEqual(loaded?.analyzedPhotoCount, 9)
        }
    }

    func testFirstSaveHydratesExistingDiskGenerationBeforeEnqueue()
        async throws {
        try await withIsolatedAnalysisCacheFile { cacheURL in
            let seeded = makeAnalysisSnapshot(
                analyzedPhotoCount: 7,
                unanalyzedPhotoCount: 0,
                isComplete: false
            ).withPersistenceGeneration(100)
            try JSONEncoder().encode(seeded).write(
                to: cacheURL,
                options: .atomic
            )

            let cache = PhotoAnalysisCache()
            let next = makeAnalysisSnapshot(
                analyzedPhotoCount: 8,
                unanalyzedPhotoCount: 0,
                isComplete: false
            )
            await cache.saveSnapshot(next)

            let loaded = await cache.loadSnapshot()
            XCTAssertEqual(loaded?.persistenceGeneration, 101)
            XCTAssertEqual(loaded?.analyzedPhotoCount, 8)
        }
    }

    func testCacheLoadChoosesNewerBackupGeneration() async throws {
        try await withIsolatedAnalysisCacheFile { cacheURL in
            let backupURL = cacheURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "photo-analysis-cache.backup.json"
                )
            let primary = makeAnalysisSnapshot(
                analyzedPhotoCount: 5,
                unanalyzedPhotoCount: 0,
                isComplete: false
            ).withPersistenceGeneration(5)
            let backup = makeAnalysisSnapshot(
                analyzedPhotoCount: 6,
                unanalyzedPhotoCount: 0,
                isComplete: false
            ).withPersistenceGeneration(6)
            try JSONEncoder().encode(primary).write(
                to: cacheURL,
                options: .atomic
            )
            try JSONEncoder().encode(backup).write(
                to: backupURL,
                options: .atomic
            )

            let loaded = await PhotoAnalysisCache().loadSnapshot()

            XCTAssertEqual(loaded?.persistenceGeneration, 6)
            XCTAssertEqual(loaded?.analyzedPhotoCount, 6)
        }
    }

    func testSavePreservesNewerBackupBeforeReplacingPrimary() async throws {
        try await withIsolatedAnalysisCacheFile { cacheURL in
            let backupURL = cacheURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "photo-analysis-cache.backup.json"
                )
            let stalePrimary = makeAnalysisSnapshot(
                analyzedPhotoCount: 5,
                unanalyzedPhotoCount: 0,
                isComplete: false
            ).withPersistenceGeneration(5)
            let recoveryBackup = makeAnalysisSnapshot(
                analyzedPhotoCount: 6,
                unanalyzedPhotoCount: 0,
                isComplete: false
            ).withPersistenceGeneration(6)
            try JSONEncoder().encode(stalePrimary).write(
                to: cacheURL,
                options: .atomic
            )
            try JSONEncoder().encode(recoveryBackup).write(
                to: backupURL,
                options: .atomic
            )

            let cache = PhotoAnalysisCache()
            let next = makeAnalysisSnapshot(
                analyzedPhotoCount: 7,
                unanalyzedPhotoCount: 0,
                isComplete: false
            )
            await cache.saveSnapshot(next)

            let preservedBackup = try JSONDecoder().decode(
                CachedPhotoAnalysisSnapshot.self,
                from: Data(contentsOf: backupURL)
            )
            let loaded = await cache.loadSnapshot()
            XCTAssertEqual(preservedBackup.persistenceGeneration, 6)
            XCTAssertEqual(preservedBackup.analyzedPhotoCount, 6)
            XCTAssertEqual(loaded?.persistenceGeneration, 7)
            XCTAssertEqual(loaded?.analyzedPhotoCount, 7)
        }
    }

    func testCorruptCurrentCheckpointFallsBackToPriorValidGeneration() async throws {
        try await withIsolatedAnalysisCacheFile { cacheURL in
            let cache = PhotoAnalysisCache()
            let prior = makeAnalysisSnapshot(
                analyzedPhotoCount: 7,
                unanalyzedPhotoCount: 3
            )
            let newest = makeAnalysisSnapshot(
                analyzedPhotoCount: 9,
                unanalyzedPhotoCount: 1
            )
            await cache.saveSnapshot(prior)
            await cache.saveSnapshot(newest)
            try Data("partial-json".utf8).write(to: cacheURL, options: .atomic)

            let recovered = await PhotoAnalysisCache().loadSnapshot()

            XCTAssertEqual(recovered?.analyzedPhotoCount, 7)
            XCTAssertEqual(recovered?.unanalyzedPhotoCount, 3)
            XCTAssertGreaterThan(recovered?.persistenceGeneration ?? 0, 0)
        }
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
            XCTAssertTrue(loaded?.isComplete == true)
            XCTAssertEqual(
                loaded?.libraryAssetIdentifiers,
                ["library-1", "library-2"]
            )
            XCTAssertEqual(loaded?.libraryAssets.count, 2)
        }
    }

    func testExistingVersionSevenSnapshotDecodesAsCompleted() throws {
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 2,
            unanalyzedPhotoCount: 0
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "isComplete")
        object.removeValue(forKey: "evaluatedAssetIdentifiers")
        object.removeValue(forKey: "scanTargetAssetIdentifiers")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            CachedPhotoAnalysisSnapshot.self,
            from: legacyData
        )

        XCTAssertTrue(decoded.isComplete)
        XCTAssertEqual(
            decoded.evaluatedAssetIdentifiers,
            decoded.libraryAssetIdentifiers
        )
        XCTAssertTrue(decoded.scanTargetAssetIdentifiers.isEmpty)
    }

    func testAnalysisCacheSurfacesPrematureCompleteSnapshotForRepair() async throws {
        try await withIsolatedAnalysisCacheFile { cacheURL in
            let cache = PhotoAnalysisCache()
            let snapshot = makeAnalysisSnapshot(
                analyzedPhotoCount: 10,
                unanalyzedPhotoCount: 0
            )
            let encoded = try JSONEncoder().encode(snapshot)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object["isComplete"] = true
            object["scanTargetCount"] = 100
            object["processedPhotoCount"] = 10
            object["progressFraction"] = 0.1
            let inconsistentData = try JSONSerialization.data(withJSONObject: object)
            try inconsistentData.write(to: cacheURL, options: .atomic)

            let loaded = await cache.loadSnapshot()

            XCTAssertNotNil(loaded)
            XCTAssertFalse(loaded?.hasConsistentCompletionState ?? true)
            let persistenceHealthy = await cache.persistenceHealthy
            XCTAssertFalse(persistenceHealthy)
        }
    }

    func testPrematureCompleteSnapshotRepairsToPartialPrefix() {
        let metadata = makeLibraryMetadata(
            ids: ["asset-1", "asset-2", "asset-3", "asset-4"]
        )
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 2,
            unanalyzedPhotoCount: 0,
            isComplete: true,
            evaluatedAssetIdentifiers: Array(metadata.keys),
            libraryMetadata: metadata
        )

        let repaired = snapshot.repairingPrematureCompletion(
            evaluatedAssetIdentifiers: ["asset-1", "asset-2"],
            scanTargetAssetIdentifiers: [
                "asset-1", "asset-2", "asset-3", "asset-4"
            ]
        )

        XCTAssertFalse(repaired.isComplete)
        XCTAssertTrue(repaired.hasConsistentCompletionState)
        XCTAssertEqual(repaired.processedPhotoCount, 2)
        XCTAssertEqual(repaired.progressFraction, 0.5)
        XCTAssertEqual(
            repaired.evaluatedAssetIdentifiers,
            ["asset-1", "asset-2"]
        )
        XCTAssertEqual(repaired.scanTargetAssetIdentifiers.count, 4)
    }

    func testCompletedZeroTargetWithNonemptyPhotoLibraryIsInconsistent() {
        let metadata = makeLibraryMetadata(ids: ["asset-1", "asset-2"])
        let snapshot = CachedPhotoAnalysisSnapshot(
            libraryTotalCount: metadata.count,
            scanTargetCount: 0,
            processedPhotoCount: 0,
            analyzedPhotoCount: 0,
            unanalyzedPhotoCount: 0,
            progressFraction: 1,
            groupsFoundCount: 0,
            reviewablePhotosCount: 0,
            reclaimableBytesFoundSoFar: 0,
            cleanupMode: .deepClean,
            resultsFreshnessState: .live,
            isComplete: true,
            evaluatedAssetIdentifiers: [],
            scanTargetAssetIdentifiers: [],
            groups: [],
            libraryAssetIdentifiers: metadata.keys.sorted(),
            libraryAssets: metadata.values.sorted {
                $0.localIdentifier < $1.localIdentifier
            }
        )

        XCTAssertFalse(snapshot.hasConsistentCompletionState)
        XCTAssertNil(
            PhotoScanResumePlanner.requiredAssetIDs(
                snapshot: snapshot,
                currentAssetIDs: Set(metadata.keys),
                currentMetadata: metadata,
                mode: .deepClean,
                forceFullRescan: false
            )
        )
    }

    func testCompletedZeroCountWithPersistedLibraryMetadataIsInconsistent() {
        let metadata = makeLibraryMetadata(ids: ["asset-1"])
        let snapshot = CachedPhotoAnalysisSnapshot(
            libraryTotalCount: 0,
            scanTargetCount: 0,
            processedPhotoCount: 0,
            analyzedPhotoCount: 0,
            unanalyzedPhotoCount: 0,
            progressFraction: 1,
            groupsFoundCount: 0,
            reviewablePhotosCount: 0,
            reclaimableBytesFoundSoFar: 0,
            cleanupMode: .deepClean,
            resultsFreshnessState: .live,
            isComplete: true,
            evaluatedAssetIdentifiers: [],
            groups: [],
            libraryAssetIdentifiers: [],
            libraryAssets: Array(metadata.values)
        )

        XCTAssertFalse(snapshot.hasConsistentCompletionState)
    }

    func testCompletedDeepCleanCannotCoverOnlyPartOfLibrary() {
        let metadata = makeLibraryMetadata(
            ids: ["asset-1", "asset-2", "asset-3"]
        )
        let snapshot = CachedPhotoAnalysisSnapshot(
            libraryTotalCount: metadata.count,
            scanTargetCount: 1,
            processedPhotoCount: 1,
            analyzedPhotoCount: 1,
            unanalyzedPhotoCount: 0,
            progressFraction: 1,
            groupsFoundCount: 0,
            reviewablePhotosCount: 0,
            reclaimableBytesFoundSoFar: 0,
            cleanupMode: .deepClean,
            resultsFreshnessState: .live,
            isComplete: true,
            evaluatedAssetIdentifiers: ["asset-1"],
            groups: [],
            libraryAssetIdentifiers: metadata.keys.sorted(),
            libraryAssets: metadata.values.sorted {
                $0.localIdentifier < $1.localIdentifier
            }
        )

        XCTAssertFalse(snapshot.hasConsistentCompletionState)
        XCTAssertNil(
            PhotoScanResumePlanner.requiredAssetIDs(
                snapshot: snapshot,
                currentAssetIDs: Set(metadata.keys),
                currentMetadata: metadata,
                mode: .deepClean,
                forceFullRescan: false
            )
        )
    }

    func testCompletedDeepCleanRequiresEveryPersistedMetadataAsset() {
        let metadata = makeLibraryMetadata(
            ids: ["asset-1", "asset-2", "asset-3"]
        )
        let snapshot = CachedPhotoAnalysisSnapshot(
            libraryTotalCount: metadata.count,
            scanTargetCount: metadata.count,
            processedPhotoCount: metadata.count,
            analyzedPhotoCount: metadata.count,
            unanalyzedPhotoCount: 0,
            progressFraction: 1,
            groupsFoundCount: 0,
            reviewablePhotosCount: 0,
            reclaimableBytesFoundSoFar: 0,
            cleanupMode: .deepClean,
            resultsFreshnessState: .live,
            isComplete: true,
            evaluatedAssetIdentifiers: [
                "asset-1", "asset-2", "unrelated-asset"
            ],
            groups: [],
            // Simulate a damaged redundant ID list while the metadata records
            // still retain the authoritative library inventory.
            libraryAssetIdentifiers: ["asset-1"],
            libraryAssets: metadata.values.sorted {
                $0.localIdentifier < $1.localIdentifier
            }
        )

        XCTAssertFalse(snapshot.hasConsistentCompletionState)
    }

    func testCompletedBoundedSpeedCleanRemainsConsistent() {
        let metadata = makeLibraryMetadata(
            ids: ["asset-1", "asset-2", "asset-3"]
        )
        let snapshot = CachedPhotoAnalysisSnapshot(
            libraryTotalCount: metadata.count,
            scanTargetCount: 1,
            processedPhotoCount: 1,
            analyzedPhotoCount: 1,
            unanalyzedPhotoCount: 0,
            progressFraction: 1,
            groupsFoundCount: 0,
            reviewablePhotosCount: 0,
            reclaimableBytesFoundSoFar: 0,
            cleanupMode: .speedClean,
            resultsFreshnessState: .live,
            isComplete: true,
            evaluatedAssetIdentifiers: ["asset-1"],
            groups: [],
            libraryAssetIdentifiers: metadata.keys.sorted(),
            libraryAssets: metadata.values.sorted {
                $0.localIdentifier < $1.localIdentifier
            }
        )

        XCTAssertTrue(snapshot.hasConsistentCompletionState)
        XCTAssertEqual(
            PhotoScanResumePlanner.requiredAssetIDs(
                snapshot: snapshot,
                currentAssetIDs: Set(metadata.keys),
                currentMetadata: metadata,
                mode: .speedClean,
                forceFullRescan: false
            ),
            []
        )
    }

    func testCompletedZeroTargetIsValidForGenuinelyEmptyPhotoLibrary() {
        let snapshot = CachedPhotoAnalysisSnapshot(
            libraryTotalCount: 0,
            scanTargetCount: 0,
            processedPhotoCount: 0,
            analyzedPhotoCount: 0,
            unanalyzedPhotoCount: 0,
            progressFraction: 1,
            groupsFoundCount: 0,
            reviewablePhotosCount: 0,
            reclaimableBytesFoundSoFar: 0,
            cleanupMode: .deepClean,
            resultsFreshnessState: .live,
            isComplete: true,
            groups: [],
            libraryAssetIdentifiers: [],
            libraryAssets: []
        )

        XCTAssertTrue(snapshot.hasConsistentCompletionState)
    }

    func testScanRunCompletionWaitsForPhotoAndSupportingFinalization() {
        XCTAssertFalse(
            HomeViewModel.isScanRunComplete(
                scanState: .completed,
                isFinalizingPhotoScan: true,
                isFinishingSupportingScans: false
            )
        )
        XCTAssertFalse(
            HomeViewModel.isScanRunComplete(
                scanState: .completed,
                isFinalizingPhotoScan: false,
                isFinishingSupportingScans: true
            )
        )
        XCTAssertTrue(
            HomeViewModel.isScanRunComplete(
                scanState: .completed,
                isFinalizingPhotoScan: false,
                isFinishingSupportingScans: false
            )
        )
    }

    func testScanCompletionLockOnlyBlocksTheFinalCompletionWindow() {
        XCTAssertFalse(
            HomeViewModel.isScanCompletionLocked(
                scanState: .scanning,
                isFinalizingPhotoScan: true,
                isFinishingSupportingScans: false
            )
        )
        XCTAssertTrue(
            HomeViewModel.isScanCompletionLocked(
                scanState: .completed,
                isFinalizingPhotoScan: true,
                isFinishingSupportingScans: false
            )
        )
        XCTAssertTrue(
            HomeViewModel.isScanCompletionLocked(
                scanState: .completed,
                isFinalizingPhotoScan: false,
                isFinishingSupportingScans: true
            )
        )
        XCTAssertFalse(
            HomeViewModel.isScanCompletionLocked(
                scanState: .completed,
                isFinalizingPhotoScan: false,
                isFinishingSupportingScans: false
            )
        )
    }

    func testSimilarPhotosPrimaryActionProtectsActiveScanProgress() {
        XCTAssertEqual(
            SimilarPhotosPrimaryAction.resolve(
                scanState: .scanning,
                hasResults: false
            ),
            .pause
        )
        XCTAssertEqual(
            SimilarPhotosPrimaryAction.resolve(
                scanState: .paused,
                hasResults: false
            ),
            .resume
        )
        XCTAssertEqual(
            SimilarPhotosPrimaryAction.resolve(
                scanState: .completed,
                hasResults: false
            ),
            .freshScan
        )
        XCTAssertEqual(
            SimilarPhotosPrimaryAction.resolve(
                scanState: .completed,
                hasResults: true
            ),
            .review
        )
    }

    func testTargetlessPartialCheckpointRebuildsScanPlan() {
        let metadata = makeLibraryMetadata(ids: ["asset-1", "asset-2"])
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 0,
            unanalyzedPhotoCount: 0,
            isComplete: false,
            evaluatedAssetIdentifiers: [],
            scanTargetAssetIdentifiers: [],
            libraryMetadata: metadata
        )

        XCTAssertNil(
            PhotoScanResumePlanner.requiredAssetIDs(
                snapshot: snapshot,
                currentAssetIDs: Set(metadata.keys),
                currentMetadata: metadata,
                mode: .deepClean,
                forceFullRescan: false
            )
        )
    }

    func testTargetlessPartialCheckpointRepairPreservesCommittedOffset() {
        let metadata = makeLibraryMetadata(
            ids: ["asset-1", "asset-2", "asset-3", "asset-4"]
        )
        let targetless = makeAnalysisSnapshot(
            analyzedPhotoCount: 2,
            unanalyzedPhotoCount: 0,
            isComplete: false,
            evaluatedAssetIdentifiers: [],
            scanTargetAssetIdentifiers: [],
            libraryMetadata: metadata
        )
        let repaired = targetless.repairingPrematureCompletion(
            evaluatedAssetIdentifiers: ["asset-1", "asset-2"],
            scanTargetAssetIdentifiers: [
                "asset-1", "asset-2", "asset-3", "asset-4"
            ]
        )

        let required = PhotoScanResumePlanner.requiredAssetIDs(
            snapshot: repaired,
            currentAssetIDs: Set(metadata.keys),
            currentMetadata: metadata,
            mode: .deepClean,
            forceFullRescan: false
        )

        XCTAssertEqual(repaired.processedPhotoCount, 2)
        XCTAssertEqual(repaired.scanTargetCount, 4)
        XCTAssertEqual(required, Set(["asset-3", "asset-4"]))
    }

    func testPartialScanResumePlannerOnlyRequestsUnfinishedAssets() {
        let metadata = makeLibraryMetadata(ids: ["asset-1", "asset-2", "asset-3"])
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 2,
            unanalyzedPhotoCount: 0,
            isComplete: false,
            evaluatedAssetIdentifiers: ["asset-1", "asset-2"],
            scanTargetAssetIdentifiers: ["asset-1", "asset-2", "asset-3"],
            libraryMetadata: metadata
        )

        let required = PhotoScanResumePlanner.requiredAssetIDs(
            snapshot: snapshot,
            currentAssetIDs: Set(metadata.keys),
            currentMetadata: metadata,
            mode: .deepClean,
            forceFullRescan: false
        )

        XCTAssertEqual(required, ["asset-3"])
    }

    func testPartialSpeedCleanResumeDoesNotExpandPastOriginalTarget() {
        let metadata = makeLibraryMetadata(
            ids: ["asset-1", "asset-2", "asset-3", "outside-speed-target"]
        )
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 1,
            unanalyzedPhotoCount: 0,
            isComplete: false,
            evaluatedAssetIdentifiers: ["asset-1"],
            scanTargetAssetIdentifiers: ["asset-1", "asset-2", "asset-3"],
            libraryMetadata: metadata
        )

        let required = PhotoScanResumePlanner.requiredAssetIDs(
            snapshot: snapshot,
            currentAssetIDs: Set(metadata.keys),
            currentMetadata: metadata,
            mode: .speedClean,
            forceFullRescan: false
        )

        XCTAssertEqual(required, ["asset-2", "asset-3"])
    }

    func testPartialResumeIncludesNewChangedAndSelectedRetryAssets() {
        let cachedMetadata = makeLibraryMetadata(
            ids: ["done", "unfinished", "retry"]
        )
        var currentMetadata = cachedMetadata
        currentMetadata["done"] = CachedPhotoAssetMetadata(
            localIdentifier: "done",
            modificationDate: Date(timeIntervalSinceReferenceDate: 9_999),
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            mediaSubtypesRawValue: 0
        )
        currentMetadata["new"] = CachedPhotoAssetMetadata(
            localIdentifier: "new",
            modificationDate: Date(),
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            mediaSubtypesRawValue: 0
        )
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 1,
            unanalyzedPhotoCount: 1,
            isComplete: false,
            evaluatedAssetIdentifiers: ["done", "retry"],
            scanTargetAssetIdentifiers: ["done", "unfinished", "retry"],
            libraryMetadata: cachedMetadata
        )

        let required = PhotoScanResumePlanner.requiredAssetIDs(
            snapshot: snapshot,
            currentAssetIDs: Set(currentMetadata.keys),
            currentMetadata: currentMetadata,
            mode: .deepClean,
            forceFullRescan: false,
            retryAssetIDs: ["retry"]
        )

        XCTAssertEqual(required, ["done", "unfinished", "retry", "new"])
    }

    func testCompletedScanResumePlannerOnlyRequestsNewAssets() {
        let cachedMetadata = makeLibraryMetadata(ids: ["asset-1", "asset-2"])
        let currentMetadata = makeLibraryMetadata(ids: ["asset-1", "asset-2", "asset-3"])
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 2,
            unanalyzedPhotoCount: 0,
            isComplete: true,
            evaluatedAssetIdentifiers: ["asset-1", "asset-2"],
            libraryMetadata: cachedMetadata,
            libraryTotalCount: cachedMetadata.count,
            scanTargetCount: 2
        )

        let required = PhotoScanResumePlanner.requiredAssetIDs(
            snapshot: snapshot,
            currentAssetIDs: Set(currentMetadata.keys),
            currentMetadata: currentMetadata,
            mode: .deepClean,
            forceFullRescan: false
        )

        XCTAssertEqual(required, ["asset-3"])
    }

    func testCompletedScanResumePlannerRetriesPreviouslyUnanalyzedAssets() {
        let cachedMetadata = makeLibraryMetadata(
            ids: ["asset-1", "asset-2", "asset-3"]
        )
        // asset-2 was attempted (so it counts as evaluated and the snapshot is
        // consistently complete) but produced no usable analysis.
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 2,
            unanalyzedPhotoCount: 1,
            isComplete: true,
            evaluatedAssetIdentifiers: ["asset-1", "asset-2", "asset-3"],
            unanalyzedAssetIdentifiers: ["asset-2"],
            libraryMetadata: cachedMetadata,
            libraryTotalCount: cachedMetadata.count,
            scanTargetCount: 3
        )

        XCTAssertTrue(snapshot.hasConsistentCompletionState)
        // Attempted-everything is not the same as analyzed-everything.
        XCTAssertFalse(snapshot.hasCompleteAnalysisCoverage)

        let required = PhotoScanResumePlanner.requiredAssetIDs(
            snapshot: snapshot,
            currentAssetIDs: Set(cachedMetadata.keys),
            currentMetadata: cachedMetadata,
            mode: .deepClean,
            forceFullRescan: false
        )

        // A plain rescan must reach the failed asset. Previously it was folded
        // into "evaluated" and only the explicit retry CTA could touch it.
        XCTAssertEqual(required, ["asset-2"])
    }

    func testResumePlannerDropsUnanalyzedAssetsThatNoLongerExist() {
        let cachedMetadata = makeLibraryMetadata(ids: ["asset-1", "asset-2"])
        let currentMetadata = makeLibraryMetadata(ids: ["asset-1"])
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 1,
            unanalyzedPhotoCount: 1,
            isComplete: true,
            evaluatedAssetIdentifiers: ["asset-1", "asset-2"],
            unanalyzedAssetIdentifiers: ["asset-2"],
            libraryMetadata: cachedMetadata,
            libraryTotalCount: cachedMetadata.count,
            scanTargetCount: 2
        )

        let required = PhotoScanResumePlanner.requiredAssetIDs(
            snapshot: snapshot,
            currentAssetIDs: Set(currentMetadata.keys),
            currentMetadata: currentMetadata,
            mode: .deepClean,
            forceFullRescan: false
        )

        // A deleted photo can never be analyzed; it must not keep the work set
        // permanently non-empty.
        XCTAssertEqual(required, [])
    }

    func testFullyAnalyzedSnapshotReportsCompleteCoverage() {
        let cachedMetadata = makeLibraryMetadata(ids: ["asset-1", "asset-2"])
        let snapshot = makeAnalysisSnapshot(
            analyzedPhotoCount: 2,
            unanalyzedPhotoCount: 0,
            isComplete: true,
            evaluatedAssetIdentifiers: ["asset-1", "asset-2"],
            libraryMetadata: cachedMetadata,
            libraryTotalCount: cachedMetadata.count,
            scanTargetCount: 2
        )

        XCTAssertTrue(snapshot.hasCompleteAnalysisCoverage)
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
        blurryAssetIdentifiers: [String] = [],
        isComplete: Bool = true,
        evaluatedAssetIdentifiers: [String] = [],
        scanTargetAssetIdentifiers: [String] = [],
        unanalyzedAssetIdentifiers: [String] = [],
        libraryMetadata: [String: CachedPhotoAssetMetadata]? = nil,
        libraryTotalCount: Int = 12,
        scanTargetCount: Int = 10
    ) -> CachedPhotoAnalysisSnapshot {
        let resolvedMetadata = libraryMetadata ?? makeLibraryMetadata(
            ids: ["library-1", "library-2"]
        )
        return CachedPhotoAnalysisSnapshot(
            savedAt: Date(timeIntervalSinceReferenceDate: 123),
            libraryTotalCount: libraryTotalCount,
            scanTargetCount: scanTargetCount,
            processedPhotoCount: analyzedPhotoCount + unanalyzedPhotoCount,
            analyzedPhotoCount: analyzedPhotoCount,
            unanalyzedPhotoCount: unanalyzedPhotoCount,
            progressFraction: 1,
            groupsFoundCount: 0,
            reviewablePhotosCount: 0,
            reclaimableBytesFoundSoFar: 0,
            cleanupMode: .deepClean,
            resultsFreshnessState: .live,
            isComplete: isComplete,
            evaluatedAssetIdentifiers: evaluatedAssetIdentifiers,
            scanTargetAssetIdentifiers: scanTargetAssetIdentifiers,
            unanalyzedAssetIdentifiers: unanalyzedAssetIdentifiers,
            groups: [],
            screenshotAssetIdentifiers: screenshotAssetIdentifiers,
            blurryAssetIdentifiers: blurryAssetIdentifiers,
            libraryAssetIdentifiers: resolvedMetadata.keys.sorted(),
            libraryAssets: resolvedMetadata.values.sorted {
                $0.localIdentifier < $1.localIdentifier
            }
        )
    }

    private func makeLibraryMetadata(
        ids: [String]
    ) -> [String: CachedPhotoAssetMetadata] {
        Dictionary(
            uniqueKeysWithValues: ids.enumerated().map { index, id in
                (
                    id,
                    CachedPhotoAssetMetadata(
                        localIdentifier: id,
                        modificationDate: Date(timeIntervalSinceReferenceDate: Double(index)),
                        pixelWidth: 4_032,
                        pixelHeight: 3_024,
                        mediaSubtypesRawValue: 0
                    )
                )
            }
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
        let backupURL = directoryURL.appendingPathComponent(
            "photo-analysis-cache.backup.json"
        )
        let originalData = try? Data(contentsOf: cacheURL)
        let originalBackupData = try? Data(contentsOf: backupURL)

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: cacheURL)
        try? fileManager.removeItem(at: backupURL)
        defer {
            if let originalData {
                try? originalData.write(to: cacheURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: cacheURL)
            }
            if let originalBackupData {
                try? originalBackupData.write(to: backupURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: backupURL)
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

private actor PhotoScanTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
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
