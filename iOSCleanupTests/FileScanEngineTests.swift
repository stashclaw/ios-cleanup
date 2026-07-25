import Photos
import UIKit
import XCTest
@testable import iOSCleanup

final class FileScanEngineTests: XCTestCase {

    func testFormattedSize50MB() {
        let file = LargeFile(
            id: UUID(),
            source: .photoLibrary(asset: PHAsset()),
            displayName: "x",
            byteSize: 52_428_800,
            creationDate: nil
        )
        XCTAssertFalse(file.formattedSize.isEmpty)
        XCTAssertTrue(file.formattedSize.contains("MB") || file.formattedSize.contains("GB"))
    }

    func testFormattedSizeContainsUnit() {
        let file = LargeFile(
            id: UUID(),
            source: .photoLibrary(asset: PHAsset()),
            displayName: "y",
            byteSize: 1_073_741_824,
            creationDate: nil
        )
        XCTAssertTrue(file.formattedSize.contains("GB"))
    }

    func testEditedVideoUsesRenderedCurrentVersionWithoutSummingOriginal() {
        let resources = [
            candidate(.video, "IMG_1001.MOV", bytes: 180_000_000),
            candidate(.adjustmentData, "Adjustments.plist", bytes: 12_000),
            candidate(.fullSizeVideo, "IMG_E1001.MOV", bytes: 92_000_000)
        ]

        let resolution = AssetResourceSizePolicy.resolveByteCount(
            candidates: resources,
            mediaKind: .video,
            measuredCurrentVersionBytes: nil,
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            duration: 60
        )

        XCTAssertEqual(resolution, AssetByteSizeResolution(bytes: 92_000_000, isEstimated: false))
        XCTAssertEqual(
            AssetResourceSizePolicy.displayFilename(from: resources, mediaKind: .video),
            "IMG_E1001.MOV"
        )
    }

    func testSlowMotionVideoDoesNotAddAdjustmentResources() {
        let resources = [
            candidate(.video, "IMG_2001.MOV", bytes: 155_000_000),
            candidate(.adjustmentData, "Adjustments.plist", bytes: 30_000),
            candidate(.adjustmentBaseVideo, "IMG_2001_BASE.MOV", bytes: 155_000_000)
        ]

        let resolution = AssetResourceSizePolicy.resolveByteCount(
            candidates: resources,
            mediaKind: .video,
            measuredCurrentVersionBytes: nil,
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            duration: 90
        )

        XCTAssertEqual(resolution.bytes, 155_000_000)
        XCTAssertFalse(resolution.isEstimated)
    }

    func testLivePhotoUsesStillImageRatherThanAddingPairedVideo() {
        let resources = [
            candidate(.photo, "IMG_3001.HEIC", bytes: 4_500_000),
            candidate(.pairedVideo, "IMG_3001.MOV", bytes: 8_500_000)
        ]

        let resolution = AssetResourceSizePolicy.resolveByteCount(
            candidates: resources,
            mediaKind: .image,
            measuredCurrentVersionBytes: nil,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: 3
        )

        XCTAssertEqual(resolution.bytes, 4_500_000)
        XCTAssertEqual(
            AssetResourceSizePolicy.displayFilename(from: resources, mediaKind: .image),
            "IMG_3001.HEIC"
        )
    }

    func testMeasuredCurrentVersionOverridesResourceMetadata() {
        let resources = [
            candidate(.video, "IMG_4001.MOV", bytes: 100_000_000),
            candidate(.fullSizeVideo, "IMG_E4001.MOV", bytes: nil)
        ]

        let resolution = AssetResourceSizePolicy.resolveByteCount(
            candidates: resources,
            mediaKind: .video,
            measuredCurrentVersionBytes: 73_000_000,
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            duration: 60
        )

        XCTAssertEqual(resolution, AssetByteSizeResolution(bytes: 73_000_000, isEstimated: false))
    }

    func testVideoFallbackIsDurationAndResolutionAware() {
        let highResolution = AssetResourceSizePolicy.estimatedByteCount(
            mediaKind: .video,
            pixelWidth: 3_840,
            pixelHeight: 2_160,
            duration: 60
        )
        let lowResolution = AssetResourceSizePolicy.estimatedByteCount(
            mediaKind: .video,
            pixelWidth: 1_280,
            pixelHeight: 720,
            duration: 60
        )

        XCTAssertGreaterThan(highResolution, lowResolution)
        XCTAssertGreaterThan(highResolution, FileScanEngine.minimumFileSizeBytes)
    }

    func testLargeVideoThresholdIsOneHundredMegabytes() {
        let threshold = Int64(100 * 1024 * 1024)

        XCTAssertEqual(FileScanEngine.minimumFileSizeBytes, threshold)
        XCTAssertFalse(FileScanPolicy.qualifies(byteSize: threshold - 1))
        XCTAssertTrue(FileScanPolicy.qualifies(byteSize: threshold))
    }

    func testVideoScanPublishesMonotonicProgressAndHonestCacheReuse() async throws {
        let assets = (0..<18).map {
            ExternalExportTestAsset(localIdentifier: "video-\($0)")
        }
        let updates = FileScanUpdateProbe()
        let engine = FileScanEngine(
            authorizationProvider: FileScanAuthorizationProvider(
                currentStatus: { .authorized },
                requestReadWrite: {
                    XCTFail("Authorized scans must not request access again")
                    return .authorized
                }
            ),
            assetProvider: StubFileScanAssetProvider(assets: assets),
            representativeResolver: { asset in
                let index = Int(
                    asset.localIdentifier.split(separator: "-").last ?? "0"
                ) ?? 0
                return PHAssetRepresentativeFile(
                    displayName: "\(asset.localIdentifier).mov",
                    byteSize: FileScanEngine.minimumFileSizeBytes
                        + Int64(index),
                    byteSizeIsEstimated: false,
                    wasCached: index != 17
                )
            }
        )

        let files = try await engine.scan { update in
            await updates.append(update)
        }
        let captured = await updates.values()

        XCTAssertEqual(
            captured.map(\.progress.processedVideoCount),
            [0, 8, 16, 18]
        )
        XCTAssertEqual(captured.last?.progress.totalVideoCount, 18)
        XCTAssertEqual(captured.last?.progress.cacheHitCount, 17)
        XCTAssertTrue(captured.last?.progress.isComplete ?? false)
        XCTAssertEqual(captured.last?.progress.progressFraction, 1)
        XCTAssertEqual(captured.last?.largeFiles?.count, 18)
        XCTAssertEqual(files.count, 18)
        XCTAssertTrue(
            zip(
                captured,
                captured.dropFirst()
            ).allSatisfy { pair in
                pair.0.progress.processedVideoCount
                    <= pair.1.progress.processedVideoCount
            }
        )
    }

    func testLargeVideoReviewDefaultsToLargestFirst() {
        let files = [
            reviewFile(name: "medium.mov", bytes: 300),
            reviewFile(name: "largest.mov", bytes: 900),
            reviewFile(name: "smallest.mov", bytes: 100)
        ]

        let sections = LargeVideoReviewOrganizer.sections(
            for: files,
            organization: .size
        )

        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections.first?.title)
        XCTAssertEqual(
            sections.first?.files.map(\.displayName),
            ["largest.mov", "medium.mov", "smallest.mov"]
        )
    }

    func testLargeVideoReviewGroupsNewestYearsAndMonthsFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let files = [
            reviewFile(
                name: "jan-2025.mov",
                bytes: 200,
                date: calendar.date(from: DateComponents(year: 2025, month: 1, day: 2))
            ),
            reviewFile(
                name: "march-2026.mov",
                bytes: 300,
                date: calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))
            ),
            reviewFile(
                name: "feb-2026.mov",
                bytes: 400,
                date: calendar.date(from: DateComponents(year: 2026, month: 2, day: 2))
            ),
            reviewFile(name: "unknown.mov", bytes: 500)
        ]

        let years = LargeVideoReviewOrganizer.sections(
            for: files,
            organization: .year,
            calendar: calendar
        )
        XCTAssertEqual(years.map(\.id), ["year-2026", "year-2025", "unknown-date"])
        XCTAssertEqual(
            years.first?.files.map(\.displayName),
            ["feb-2026.mov", "march-2026.mov"]
        )

        let months = LargeVideoReviewOrganizer.sections(
            for: files,
            organization: .month,
            calendar: calendar
        )
        XCTAssertEqual(
            months.map(\.id),
            ["month-2026-03", "month-2026-02", "month-2025-01", "unknown-date"]
        )
    }

    @MainActor
    func testLargeVideoReviewMemoSkipsUnchangedResorts() {
        let first = reviewFile(name: "first.mov", bytes: 100)
        let second = reviewFile(name: "second.mov", bytes: 200)
        let files = [first, second]
        let memo = LargeVideoReviewSectionMemo()

        _ = memo.sections(
            for: files,
            hiddenFileIDs: [],
            organization: .size
        )
        _ = memo.sections(
            for: files,
            hiddenFileIDs: [],
            organization: .size
        )

        XCTAssertEqual(memo.recomputationCount, 1)

        _ = memo.sections(
            for: files,
            hiddenFileIDs: [first.id],
            organization: .size
        )
        XCTAssertEqual(memo.recomputationCount, 2)
    }

    func testLargeVideoExportSelectionIncludesOnlyExplicitAssetsInReviewOrder() {
        let files = [
            selectionReviewFile(
                assetID: "asset-a",
                name: "first.mov",
                bytes: 100
            ),
            selectionReviewFile(
                assetID: "asset-b",
                name: "not-selected.mov",
                bytes: 200
            ),
            selectionReviewFile(
                assetID: "asset-c",
                name: "third.mov",
                bytes: 300
            )
        ]

        let selected = LargeVideoExportSelection.selectedFiles(
            in: files,
            assetIDs: ["asset-c", "asset-a"]
        )

        XCTAssertEqual(
            selected.map { $0.photoAsset.localIdentifier },
            ["asset-a", "asset-c"]
        )
        XCTAssertEqual(
            selected.map(\.displayName),
            ["first.mov", "third.mov"]
        )
        XCTAssertEqual(
            LargeVideoExportSelection.totalBytes(in: selected),
            400
        )
    }

    func testLargeVideoExportSelectionSurvivesRefreshedRowsByAssetIdentifier() {
        let originalAID = UUID()
        let originalBID = UUID()
        let originalFiles = [
            selectionReviewFile(
                assetID: "asset-a",
                name: "a.mov",
                bytes: 100,
                id: originalAID
            ),
            selectionReviewFile(
                assetID: "asset-b",
                name: "b.mov",
                bytes: 200,
                id: originalBID
            )
        ]
        let selectedAssetIDs = Set(
            originalFiles.map { $0.photoAsset.localIdentifier }
        ).union(["removed-asset"])
        let refreshedFiles = [
            selectionReviewFile(
                assetID: "asset-b",
                name: "b-refreshed.mov",
                bytes: 220
            ),
            selectionReviewFile(
                assetID: "asset-c",
                name: "c.mov",
                bytes: 300
            )
        ]

        let reconciled = LargeVideoExportSelection.reconciledAssetIDs(
            selectedAssetIDs,
            with: refreshedFiles
        )
        let selectedAfterRefresh = LargeVideoExportSelection.selectedFiles(
            in: refreshedFiles,
            assetIDs: reconciled
        )

        XCTAssertEqual(reconciled, ["asset-b"])
        XCTAssertEqual(
            selectedAfterRefresh.map { $0.photoAsset.localIdentifier },
            ["asset-b"]
        )
        XCTAssertNotEqual(selectedAfterRefresh.first?.id, originalBID)
    }

    func testLargeVideoExportSelectionSurvivesPartialRefreshPublications() {
        let selectedAssetIDs: Set<String> = [
            "asset-a",
            "asset-b",
            "removed-asset"
        ]
        let partialFiles = [
            selectionReviewFile(
                assetID: "asset-a",
                name: "a-partial.mov",
                bytes: 100
            )
        ]
        let completedFiles = [
            selectionReviewFile(
                assetID: "asset-a",
                name: "a.mov",
                bytes: 100
            ),
            selectionReviewFile(
                assetID: "asset-b",
                name: "b.mov",
                bytes: 200
            ),
            selectionReviewFile(
                assetID: "asset-c",
                name: "c.mov",
                bytes: 300
            )
        ]

        let selectionDuringScan =
            LargeVideoExportSelection.reconciledAssetIDs(
                selectedAssetIDs,
                with: partialFiles,
                resultsAreAuthoritative: false
            )
        let selectionAfterCompletion =
            LargeVideoExportSelection.reconciledAssetIDs(
                selectionDuringScan,
                with: completedFiles,
                resultsAreAuthoritative: true
            )

        XCTAssertEqual(selectionDuringScan, selectedAssetIDs)
        XCTAssertEqual(
            selectionAfterCompletion,
            ["asset-a", "asset-b"]
        )
    }

    @MainActor
    func testLargeVideoExportSelectionQueuesOnlySelectedAssets() {
        let suiteName = "LargeVideoSelectionTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let files = [
            selectionReviewFile(
                assetID: "asset-a",
                name: "a.mov",
                bytes: 100
            ),
            selectionReviewFile(
                assetID: "asset-b",
                name: "b.mov",
                bytes: 200
            ),
            selectionReviewFile(
                assetID: "asset-c",
                name: "c.mov",
                bytes: 300
            )
        ]
        let selected = LargeVideoExportSelection.selectedFiles(
            in: files,
            assetIDs: ["asset-a", "asset-c"]
        )
        let store = ExportAlbumStore(defaults: defaults)

        store.add(selected.map(\.photoAsset))

        XCTAssertEqual(store.assetIDs, ["asset-a", "asset-c"])
        XCTAssertFalse(store.contains("asset-b"))
    }

    func testExportAlbumSelectionReturnsOnlyExplicitUniqueAssets() {
        let first = ExternalExportTestAsset(localIdentifier: "asset-a")
        let repeatedFirst =
            ExternalExportTestAsset(localIdentifier: "asset-a")
        let second = ExternalExportTestAsset(localIdentifier: "asset-b")

        let selected = ExportAlbumSelection.selectedAssets(
            in: [first, repeatedFirst, second],
            assetIDs: ["asset-b"]
        )

        XCTAssertEqual(
            selected.map(\.localIdentifier),
            ["asset-b"]
        )
        XCTAssertEqual(
            ExportAlbumSelection.reconciledAssetIDs(
                ["asset-a", "missing"],
                availableAssetIDs: ["asset-a", "asset-b"]
            ),
            ["asset-a"]
        )
    }

    func testFileSizeRepositoryPersistsProvenanceAcrossInstances() async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetFileSizeRepository-\(UUID().uuidString)")
        let fileURL = folder.appendingPathComponent("sizes.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = AssetFileSizeCacheKey(
            localIdentifier: "video-1",
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        let record = AssetFileSizeRecord(
            bytes: 175_000_000,
            provenance: .measuredCurrentVersion,
            savedAt: Date(timeIntervalSince1970: 200)
        )

        let writer = AssetFileSizeRepository(fileURL: fileURL)
        await writer.store(record, for: key)
        await writer.flush()

        let reader = AssetFileSizeRepository(fileURL: fileURL)
        let restored = await reader.value(for: key)

        XCTAssertEqual(restored, record)
        XCTAssertFalse(restored?.isEstimated ?? true)
    }

    private func reviewFile(
        name: String,
        bytes: Int64,
        date: Date? = nil
    ) -> LargeFile {
        LargeFile(
            id: UUID(),
            source: .photoLibrary(asset: PHAsset()),
            displayName: name,
            byteSize: bytes,
            creationDate: date
        )
    }

    private func selectionReviewFile(
        assetID: String,
        name: String,
        bytes: Int64,
        id: UUID = UUID()
    ) -> LargeFile {
        LargeFile(
            id: id,
            source: .photoLibrary(
                asset: ExternalExportTestAsset(
                    localIdentifier: assetID
                )
            ),
            displayName: name,
            byteSize: bytes,
            creationDate: nil
        )
    }

    func testFileSizeRepositoryInvalidatesChangedAssetVersion() async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetFileSizeVersion-\(UUID().uuidString)")
        let fileURL = folder.appendingPathComponent("sizes.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalKey = AssetFileSizeCacheKey(
            localIdentifier: "video-1",
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        let changedKey = AssetFileSizeCacheKey(
            localIdentifier: "video-1",
            modificationDate: Date(timeIntervalSince1970: 101)
        )
        let record = AssetFileSizeRecord(
            bytes: 50_000_000,
            provenance: .estimated,
            savedAt: Date()
        )
        let repository = AssetFileSizeRepository(fileURL: fileURL)

        await repository.store(record, for: originalKey)

        let changedValue = await repository.value(for: changedKey)
        let originalValue = await repository.value(for: originalKey)
        XCTAssertNil(changedValue)
        XCTAssertTrue(originalValue?.isEstimated ?? false)
    }

    func testImageRepositoryCoalescesIdenticalRequestsAndCachesResult() async {
        let repository = PhotoImageRepository(maximumDecodedByteCost: 1_024 * 1_024)
        let probe = ImageOperationProbe(delayNanoseconds: 80_000_000)
        let key = imageRequestKey(intent: .thumbnail)

        async let first = repository.image(for: key) {
            await probe.makeImage()
        }
        async let second = repository.image(for: key) {
            await probe.makeImage()
        }
        let initialResults = await [first, second]
        let cachedResult = await repository.image(for: key) {
            await probe.makeImage()
        }

        XCTAssertTrue(initialResults.allSatisfy { $0 != nil })
        XCTAssertNotNil(cachedResult)
        XCTAssertEqual(probe.startedCount, 1)
        let inFlightCount = await repository.debugInFlightRequestCount()
        XCTAssertEqual(inFlightCount, 0)
    }

    func testImageRepositorySeparatesThumbnailAndReviewQuality() async {
        let repository = PhotoImageRepository(maximumDecodedByteCost: 1_024 * 1_024)
        let probe = ImageOperationProbe(delayNanoseconds: 0)

        _ = await repository.image(for: imageRequestKey(intent: .thumbnail)) {
            await probe.makeImage()
        }
        _ = await repository.image(for: imageRequestKey(intent: .review)) {
            await probe.makeImage()
        }

        XCTAssertEqual(probe.startedCount, 2)
        let cachedCount = await repository.debugCachedImageCount()
        XCTAssertEqual(cachedCount, 2)
    }

    func testImageRequestKeyIncludesVersionSizeModeQualityAndNetworkPolicy() {
        let base = imageRequestKey(intent: .thumbnail)
        let identical = imageRequestKey(intent: .thumbnail)
        let review = imageRequestKey(intent: .review)
        let changedVersion = PhotoImageRequestKey(
            localIdentifier: "asset-1",
            modificationDate: Date(timeIntervalSince1970: 101),
            targetSize: CGSize(width: 144, height: 144),
            contentMode: .aspectFill,
            qualityIntent: .thumbnail,
            allowsNetworkAccess: false
        )

        XCTAssertEqual(base, identical)
        XCTAssertNotEqual(base, review)
        XCTAssertNotEqual(base, changedVersion)
    }

    func testImageRepositoryDoesNotCacheImageOverDecodedMemoryLimit() async {
        let repository = PhotoImageRepository(maximumDecodedByteCost: 1)
        let probe = ImageOperationProbe(delayNanoseconds: 0)
        let key = imageRequestKey(intent: .thumbnail)

        _ = await repository.image(for: key) {
            await probe.makeImage()
        }
        _ = await repository.image(for: key) {
            await probe.makeImage()
        }

        let cachedCount = await repository.debugCachedImageCount()
        XCTAssertEqual(cachedCount, 0)
        XCTAssertEqual(probe.startedCount, 2)
    }

    func testImageRepositoryCancelsPhotoWorkAfterFinalConsumerLeaves() async {
        let repository = PhotoImageRepository(maximumDecodedByteCost: 1_024 * 1_024)
        let probe = ImageOperationProbe(delayNanoseconds: 5_000_000_000)
        let key = imageRequestKey(intent: .thumbnail)
        let request = Task {
            await repository.image(for: key) {
                await probe.makeImage()
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        request.cancel()
        _ = await request.value
        for _ in 0..<20 where probe.cancelledCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(probe.startedCount, 1)
        XCTAssertEqual(probe.cancelledCount, 1)
        let inFlightCount = await repository.debugInFlightRequestCount()
        XCTAssertEqual(inFlightCount, 0)
    }

    func testImageRequestTimeoutResumesBeforeBlockingPhotoKitCancellation()
        async {
        let firstState = PhotoImageRequestState()
        let secondState = PhotoImageRequestState()
        let firstCancellationStarted = expectation(
            description: "First PhotoKit cancellation started"
        )
        let secondCancellationStarted = expectation(
            description: "Second PhotoKit cancellation started"
        )
        let firstContinuationFinished = expectation(
            description: "First image continuation finished"
        )
        let secondContinuationFinished = expectation(
            description: "Second image continuation finished"
        )
        let releaseFirstCancellation = DispatchSemaphore(value: 0)
        defer { releaseFirstCancellation.signal() }

        let firstResultTask = Task {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<UIImage?, Never>) in
                firstState.install(continuation)
            }
        }
        let secondResultTask = Task {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<UIImage?, Never>) in
                secondState.install(continuation)
            }
        }

        firstState.setRequestID(42) { _ in }
        secondState.setRequestID(43) { _ in }
        firstState.cancel { _ in
            firstCancellationStarted.fulfill()
            releaseFirstCancellation.wait()
        }
        Task {
            _ = await firstResultTask.value
            firstContinuationFinished.fulfill()
        }
        await fulfillment(
            of: [firstCancellationStarted, firstContinuationFinished],
            timeout: 1
        )

        // The first PhotoKit call remains blocked. The bounded executor must
        // still start a second cancellation instead of serially stranding it.
        secondState.cancel { _ in
            secondCancellationStarted.fulfill()
        }
        Task {
            _ = await secondResultTask.value
            secondContinuationFinished.fulfill()
        }
        await fulfillment(
            of: [secondCancellationStarted, secondContinuationFinished],
            timeout: 1
        )
    }

    func testDeniedAuthorizationThrowsTypedPermissionErrorWithoutRequestingAgain() async {
        let engine = FileScanEngine(
            authorizationProvider: FileScanAuthorizationProvider(
                currentStatus: { .denied },
                requestReadWrite: {
                    XCTFail("A decided authorization state must not trigger another request")
                    return .denied
                }
            )
        )

        do {
            _ = try await engine.scan()
            XCTFail("Expected a typed permission error")
        } catch let error as FileScanError {
            XCTAssertEqual(error, .permissionDenied(.denied))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNotDeterminedAuthorizationRequestsOnceThenThrowsTypedDenial() async {
        let probe = FileScanAuthorizationRequestProbe()
        let engine = FileScanEngine(
            authorizationProvider: FileScanAuthorizationProvider(
                currentStatus: { .notDetermined },
                requestReadWrite: {
                    await probe.request(returning: .denied)
                }
            )
        )

        do {
            _ = try await engine.scan()
            XCTFail("Expected a typed permission error")
        } catch let error as FileScanError {
            XCTAssertEqual(error, .permissionDenied(.denied))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requestCount = await probe.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testDeletionCancellationPolicyTreatsUndoAndPhotosCancellationAsBenign() {
        XCTAssertTrue(FileDeletionErrorPolicy.isBenignCancellation(CancellationError()))

        let photosCancellation = NSError(
            domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.userCancelled.rawValue
        )
        XCTAssertTrue(FileDeletionErrorPolicy.isBenignCancellation(photosCancellation))

        let unrelatedError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        XCTAssertFalse(FileDeletionErrorPolicy.isBenignCancellation(unrelatedError))
    }

    func testExternalExportProgressUsesClampedCurrentFileFraction() {
        let halfway = ExternalPhotoExportProgress(
            completedFileCount: 2,
            totalFileCount: 4,
            currentFilename: "video.mov",
            currentFileFraction: 0.5
        )
        let belowZero = ExternalPhotoExportProgress(
            completedFileCount: 2,
            totalFileCount: 4,
            currentFilename: "video.mov",
            currentFileFraction: -1
        )
        let aboveOne = ExternalPhotoExportProgress(
            completedFileCount: 2,
            totalFileCount: 4,
            currentFilename: "video.mov",
            currentFileFraction: 2
        )

        XCTAssertEqual(halfway.overallFraction, 0.625, accuracy: 0.000_001)
        XCTAssertEqual(belowZero.overallFraction, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(aboveOne.overallFraction, 0.75, accuracy: 0.000_001)
    }

    @MainActor
    func testExternalExportSessionGateAllowsOnlyOneActiveExport() throws {
        let gate = ExternalPhotoExportSessionGate.shared
        let firstToken = try XCTUnwrap(gate.acquire())

        XCTAssertNil(gate.acquire())

        gate.release(firstToken)
        let secondToken = try XCTUnwrap(gate.acquire())
        XCTAssertNotEqual(firstToken, secondToken)
        gate.release(secondToken)
    }

    @available(iOS 16.1, *)
    func testExportActivityShowsPreparingStateBeforeResourceCountIsKnown() {
        let state = PhotoDuckExportActivityAttributes.ContentState(
            completedFileCount: 0,
            totalFileCount: 0,
            currentFilename: nil,
            overallFraction: 0,
            phase: .exporting
        )

        XCTAssertEqual(state.statusLine, "Preparing export…")
    }

    func testExternalResourceWriteStateStreamsBytesAndFinishesOnce()
        async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ExternalResourceWriteTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = folder.appendingPathComponent("video.partial")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil
            )
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = ExternalPhotoResourceWriteState(
            fileHandle: try FileHandle(forWritingTo: fileURL),
            resourceManager: .default()
        )
        let expected = Data([0, 1, 2, 3, 4, 5])

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            XCTAssertTrue(state.install(continuation))
            state.receive(expected)
            state.complete(nil)
            state.complete(nil)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), expected)
    }

    func testExternalResourceWriteStatePreservesBufferedChunkOrder()
        async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ExternalResourceBufferTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = folder.appendingPathComponent("large-video.partial")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil
            )
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = ExternalPhotoResourceWriteState(
            fileHandle: try FileHandle(forWritingTo: fileURL),
            resourceManager: .default()
        )
        let chunks = [
            Data(repeating: 0x11, count: 400_000),
            Data(repeating: 0x22, count: 400_000),
            Data(repeating: 0x33, count: 400_000)
        ]
        let expected = chunks.reduce(into: Data()) {
            $0.append($1)
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            XCTAssertTrue(state.install(continuation))
            chunks.forEach(state.receive)
            state.complete(nil)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), expected)
    }

    func testExternalResourceWriteStateCancellationWinsOverCompletion()
        async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ExternalResourceCancelTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = folder.appendingPathComponent("video.partial")
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: nil
                )
            )
            defer { try? FileManager.default.removeItem(at: folder) }
            let state = ExternalPhotoResourceWriteState(
                fileHandle: try FileHandle(forWritingTo: fileURL),
                resourceManager: .default()
            )

            do {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    XCTAssertTrue(state.install(continuation))
                    state.cancel()
                    state.complete(nil)
                }
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected: a later PhotoKit completion must not overwrite it.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Could not prepare cancellation test: \(error)")
        }
    }

    func testExternalResourceWriteStateResumesAnExistingPrefix() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ExternalResourceResumeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = folder.appendingPathComponent("video.partial")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("abcd".utf8).write(to: fileURL)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        let state = ExternalPhotoResourceWriteState(
            fileHandle: handle,
            resourceManager: .default(),
            bytesToSkip: 4
        )

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            XCTAssertTrue(state.install(continuation))
            state.receive(Data("abcdefgh".utf8))
            state.complete(nil)
        }

        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            Data("abcdefgh".utf8)
        )
    }

    func testCapacityReadingIgnoresZeroFromNonLocalVolumes() {
        // External SSDs and iCloud Drive surface through the Files provider and
        // report 0 for volumeAvailableCapacityForImportantUsage rather than
        // reporting nothing. Trusting that zero aborted exports to drives with
        // terabytes free, with "not enough free space".
        XCTAssertEqual(
            ExternalPhotoExportCapacity.firstTrustedCapacity([0, 2_000_000_000]),
            2_000_000_000
        )
        XCTAssertEqual(
            ExternalPhotoExportCapacity.firstTrustedCapacity([nil, 0, 512]),
            512
        )
        XCTAssertEqual(
            ExternalPhotoExportCapacity.firstTrustedCapacity([9_000, 1]),
            9_000,
            "The first trustworthy reading wins."
        )
    }

    func testUnknownCapacityDoesNotBlockExport() {
        // No source produced a believable figure. Blocking here would make a
        // perfectly good destination permanently unusable, so the guard must
        // stay permissive and let the real write surface any actual failure.
        XCTAssertNil(
            ExternalPhotoExportCapacity.firstTrustedCapacity([nil, 0, nil])
        )
        XCTAssertTrue(
            ExternalPhotoExportCapacity.hasCapacity(
                estimatedAssetBytes: 8_000_000_000,
                availableBytes: nil
            )
        )
    }

    func testExternalExportCapacityPreservesDriveReserve() {
        let reserve =
            ExternalPhotoExportCapacity.minimumFreeSpaceReserveBytes
        XCTAssertTrue(
            ExternalPhotoExportCapacity.hasCapacity(
                estimatedAssetBytes: 5_000_000_000,
                availableBytes: 5_000_000_000 + reserve
            )
        )
        XCTAssertFalse(
            ExternalPhotoExportCapacity.hasCapacity(
                estimatedAssetBytes: 5_000_000_000,
                availableBytes: 5_000_000_000 + reserve - 1
            )
        )
        XCTAssertTrue(
            ExternalPhotoExportCapacity.hasCapacity(
                estimatedAssetBytes: 0,
                availableBytes: 1
            )
        )
    }

    func testExternalExportSanitizesUnsafeFilenames() {
        XCTAssertEqual(
            ExternalPhotoExportNaming.sanitizedFilename(
                "../Summer/Trip:IMG?.HEIC"
            ),
            "..-Summer-Trip-IMG-.HEIC"
        )
        XCTAssertEqual(
            ExternalPhotoExportNaming.sanitizedFilename(".."),
            "photo-resource"
        )
    }

    func testExternalExportCreatesCaseInsensitiveCollisionSafeNames() {
        var usedNames = Set<String>()
        let first = ExternalPhotoExportNaming.uniqueFilename(
            preferredName: "IMG_0001.HEIC",
            assetIndex: 0,
            resourceIndex: 0,
            usedNames: &usedNames
        )
        let second = ExternalPhotoExportNaming.uniqueFilename(
            preferredName: "img_0001.heic",
            assetIndex: 1,
            resourceIndex: 0,
            usedNames: &usedNames
        )

        XCTAssertEqual(first, "IMG_0001.HEIC")
        XCTAssertEqual(second, "img_0001-2-1-1.heic")
        XCTAssertEqual(usedNames.count, 2)
    }

    func testPartialExportResultSeparatesVerifiedAndFailedAssets() {
        let result = ExternalPhotoExportResult(
            directoryURL: URL(fileURLWithPath: "/tmp/PhotoDuck Export"),
            requestedAssetCount: 3,
            resumedAssetCount: 0,
            exportedAssetIDs: ["asset-a", "asset-c"],
            failures: [
                ExternalPhotoExportItemFailure(
                    assetID: "asset-b",
                    filename: "b.mov",
                    message: "Drive disconnected"
                )
            ],
            wasCancelled: false,
            fileCount: 2,
            processedFileCount: 3,
            totalPlannedFileCount: 3,
            totalBytes: 300
        )

        XCTAssertEqual(result.assetCount, 2)
        XCTAssertEqual(result.failedAssetCount, 1)
        XCTAssertTrue(result.hasPartialSuccess)
        XCTAssertEqual(result.exportedAssetIDs, ["asset-a", "asset-c"])
    }

    func testExternalExportRejectsEmptySelectionBeforeCreatingFiles() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ExternalPhotoExportTests-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            _ = try await ExternalPhotoExportService().export(
                assets: [],
                to: folder
            )
            XCTFail("Expected an empty-selection error")
        } catch let error as ExternalPhotoExportError {
            guard case .emptySelection = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testExternalExportRejectsDuplicateAssetsBeforeCreatingFiles() async {
        let asset = ExternalExportTestAsset(localIdentifier: "same-asset")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ExternalPhotoExportDuplicateTests-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            _ = try await ExternalPhotoExportService().export(
                assets: [asset, asset],
                to: folder
            )
            XCTFail("Expected a duplicate-identifier error")
        } catch let error as ExternalPhotoExportError {
            guard case .duplicateAssetIdentifiers = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testExportAlbumDeduplicatesAndPersistsAssetIdentifiers() {
        let suiteName = "ExportAlbumTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let first = ExternalExportTestAsset(localIdentifier: "asset-1")
        let second = ExternalExportTestAsset(localIdentifier: "asset-2")
        let store = ExportAlbumStore(defaults: defaults)

        store.add([first, first, second])

        XCTAssertEqual(store.assetIDs, ["asset-1", "asset-2"])
        XCTAssertEqual(
            store.assets.map(\.localIdentifier),
            ["asset-1", "asset-2"]
        )

        let reloadedStore = ExportAlbumStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.assetIDs, ["asset-1", "asset-2"])
    }

    @MainActor
    func testExportAlbumRemovalAndClearUseExplicitIdentifiers() {
        let suiteName = "ExportAlbumRemovalTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let first = ExternalExportTestAsset(localIdentifier: "asset-1")
        let second = ExternalExportTestAsset(localIdentifier: "asset-2")
        let third = ExternalExportTestAsset(localIdentifier: "asset-3")
        let store = ExportAlbumStore(defaults: defaults)
        store.add([first, second, third])

        store.remove(assetIDs: ["asset-2"])

        XCTAssertEqual(store.assetIDs, ["asset-1", "asset-3"])
        XCTAssertEqual(
            store.assets.map(\.localIdentifier),
            ["asset-1", "asset-3"]
        )

        store.clear()

        XCTAssertTrue(store.assetIDs.isEmpty)
        XCTAssertTrue(store.assets.isEmpty)
    }

    func testDiagnosticLogPersistsNewestBoundedEventsAcrossRelaunch() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticRingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(
            timeIntervalSince1970:
                floor(Date().timeIntervalSince1970)
        )
        let store = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            maximumEventCount: 3,
            maximumFileBytes: 16 * 1_024,
            sessionID: "session-a"
        )

        for index in 0..<5 {
            await store.record(
                .videoScanProgress(
                    totalCount: 5,
                    processedCount: index,
                    cacheHitCount: index,
                    qualifyingCount: index,
                    progressPercent: index * 20,
                    isComplete: index == 4,
                    at: now.addingTimeInterval(TimeInterval(index))
                )
            )
        }

        let currentEvents = await store.storedEvents()
        XCTAssertEqual(
            currentEvents.compactMap { $0.fields["processed"] },
            ["2", "3", "4"]
        )

        let reloadedStore = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            maximumEventCount: 3,
            maximumFileBytes: 16 * 1_024,
            sessionID: "session-b"
        )
        let reloadedEvents = await reloadedStore.storedEvents()

        XCTAssertEqual(
            reloadedEvents.map(\.fields),
            currentEvents.map(\.fields)
        )
        XCTAssertEqual(
            reloadedEvents.map(\.name),
            currentEvents.map(\.name)
        )
        XCTAssertEqual(reloadedEvents.map(\.sessionID), [
            "session-a", "session-a", "session-a"
        ])
    }

    func testDiagnosticLogConcurrentRecordsRemainDecodable() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticConcurrentTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            maximumEventCount: 100,
            maximumFileBytes: 64 * 1_024,
            sessionID: "concurrent"
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    await store.record(
                        .photoScanProgress(
                            processedCount: index,
                            targetCount: 50,
                            analyzedCount: index,
                            unanalyzedCount: 0,
                            groupCount: 0,
                            progressPercent: index * 2,
                            isCompleteUpdate: false
                        )
                    )
                }
            }
        }

        let reloadedStore = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            maximumEventCount: 100,
            maximumFileBytes: 64 * 1_024,
            sessionID: "reload"
        )
        let reloadedEvents = await reloadedStore.storedEvents()

        XCTAssertEqual(reloadedEvents.count, 50)
        XCTAssertEqual(
            Set(reloadedEvents.compactMap { $0.fields["processed"] }).count,
            50
        )
    }

    func testDiagnosticReportIsRedactedVersionedAndBounded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticReportTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            maximumEventCount: 200,
            maximumFileBytes: 64 * 1_024,
            maximumExportBytes: 4 * 1_024,
            sessionID: "report"
        )
        let eventBaseDate = Date().addingTimeInterval(-200)

        for index in 0..<100 {
            await store.record(
                .photoScanProgress(
                    processedCount: index,
                    targetCount: 100,
                    analyzedCount: index,
                    unanalyzedCount: 0,
                    groupCount: 0,
                    progressPercent: index,
                    isCompleteUpdate: index == 99,
                    at: eventBaseDate.addingTimeInterval(
                        TimeInterval(index)
                    )
                )
            )
        }
        let privateError = NSError(
            domain: "asset-local-identifier-123",
            code: -77,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "IMG_0042.MOV /private/var/mobile/secret "
                    + "+1-555-0100 Justin Contact"
            ]
        )
        let safeFailure = PhotoDuckDiagnosticFailure(
            kind: .photoScan,
            error: privateError
        )
        await store.record(
            .photoScanTerminated(
                outcome: .failed,
                processedCount: 99,
                targetCount: 100,
                analyzedCount: 99,
                unanalyzedCount: 0,
                groupCount: 0,
                failure: safeFailure,
                at: eventBaseDate.addingTimeInterval(101)
            )
        )
        let persistentBytes = try XCTUnwrap(
            (
                try FileManager.default.attributesOfItem(
                    atPath: fileURL.path
                )[.size] as? NSNumber
            )?.intValue
        )
        XCTAssertLessThanOrEqual(persistentBytes, 64 * 1_024)

        let reportURL = try await store.exportReport(
            snapshot: diagnosticSnapshot()
        )
        defer { try? FileManager.default.removeItem(at: reportURL) }
        let secondReportURL = try await store.exportReport(
            snapshot: diagnosticSnapshot()
        )
        defer { try? FileManager.default.removeItem(at: secondReportURL) }
        XCTAssertNotEqual(reportURL, secondReportURL)
        let data = try Data(contentsOf: reportURL)
        XCTAssertLessThanOrEqual(data.count, 4 * 1_024)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(
            PhotoDuckDiagnosticReportEnvelope.self,
            from: data
        )

        XCTAssertEqual(
            report.schemaVersion,
            PhotoDuckDiagnosticReportEnvelope.schemaVersion
        )
        XCTAssertEqual(report.snapshot.processedCount, 8)
        XCTAssertEqual(report.snapshot.checkpoint?.generation, 4)
        XCTAssertFalse(report.events.isEmpty)
        XCTAssertTrue(report.eventsTrimmedForExport)
        XCTAssertTrue(report.privacyNotice.contains("no photos"))
        XCTAssertFalse(
            report.events.contains { $0.fields["processed"] == "0" }
        )
        XCTAssertEqual(report.events.last?.fields["error_code"], "-77")
        XCTAssertTrue(
            report.events.contains {
                $0.fields["error_kind"] == "photo_scan"
                    && $0.fields["error_code"] == "-77"
                    && $0.fields["error_domain"] == nil
            }
        )

        let reportText = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )
        for forbiddenValue in [
            "asset-local-identifier-123",
            "IMG_0042.MOV",
            "/private/var/mobile/secret",
            "+1-555-0100",
            "Justin Contact"
        ] {
            XCTAssertFalse(reportText.contains(forbiddenValue))
        }
    }

    func testDiagnosticLogHonorsByteBoundAndRetainsNewestEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticSingleEventTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            maximumEventCount: 10,
            maximumFileBytes: 512,
            sessionID: "single-event"
        )
        let eventBaseDate = Date().addingTimeInterval(-10)
        for index in 0..<5 {
            await store.record(
                .photoScanProgress(
                    processedCount: index,
                    targetCount: 5,
                    analyzedCount: index,
                    unanalyzedCount: 0,
                    groupCount: 0,
                    progressPercent: index * 20,
                    isCompleteUpdate: index == 4,
                    at: eventBaseDate.addingTimeInterval(
                        TimeInterval(index)
                    )
                )
            )
        }

        let persistentBytes = try XCTUnwrap(
            (
                try FileManager.default.attributesOfItem(
                    atPath: fileURL.path
                )[.size] as? NSNumber
            )?.intValue
        )
        XCTAssertLessThanOrEqual(persistentBytes, 512)
        let currentEvents = await store.storedEvents()
        XCTAssertEqual(currentEvents.last?.fields["processed"], "4")
        XCTAssertFalse(
            currentEvents.contains { $0.fields["processed"] == "0" }
        )

        let reloadedStore = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            maximumEventCount: 10,
            maximumFileBytes: 512,
            sessionID: "reload"
        )
        let reloadedEvents = await reloadedStore.storedEvents()
        XCTAssertEqual(reloadedEvents.last?.fields["processed"], "4")
        XCTAssertEqual(
            reloadedEvents.map(\.fields),
            currentEvents.map(\.fields)
        )
    }

    func testDiagnosticLogRepairsTornTailBeforeNextAppend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticTornTailTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            sessionID: "writer"
        )
        await writer.record(
            .photoScanProgress(
                processedCount: 1,
                targetCount: 2,
                analyzedCount: 1,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 50,
                isCompleteUpdate: false
            )
        )
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"torn\":".utf8))
        try handle.close()

        let recoveringStore = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            sessionID: "recovery"
        )
        let recoveredEvents = await recoveringStore.storedEvents()
        XCTAssertEqual(
            recoveredEvents.compactMap { $0.fields["processed"] },
            ["1"]
        )
        await recoveringStore.record(
            .photoScanProgress(
                processedCount: 2,
                targetCount: 2,
                analyzedCount: 2,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 100,
                isCompleteUpdate: true
            )
        )

        let reloadedStore = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            sessionID: "reload"
        )
        let reloadedEvents = await reloadedStore.storedEvents()
        XCTAssertEqual(
            reloadedEvents.compactMap { $0.fields["processed"] },
            ["1", "2"]
        )
    }

    func testDiagnosticLogUsesCurrentClockForRetention() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticRetentionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            retentionInterval: 7 * 24 * 60 * 60,
            sessionID: "retention",
            nowProvider: { now }
        )

        await store.record(
            .photoScanProgress(
                processedCount: 0,
                targetCount: 2,
                analyzedCount: 0,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 0,
                isCompleteUpdate: false,
                at: now.addingTimeInterval(-8 * 24 * 60 * 60)
            )
        )
        await store.record(
            .photoScanProgress(
                processedCount: 1,
                targetCount: 2,
                analyzedCount: 1,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 50,
                isCompleteUpdate: false,
                at: now.addingTimeInterval(8 * 24 * 60 * 60)
            )
        )
        await store.record(
            .photoScanProgress(
                processedCount: 2,
                targetCount: 2,
                analyzedCount: 2,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 100,
                isCompleteUpdate: true,
                at: now
            )
        )

        let events = await store.storedEvents()
        XCTAssertEqual(
            events.compactMap { $0.fields["processed"] },
            ["1", "2"]
        )
        XCTAssertTrue(events.allSatisfy { $0.timestamp <= now })
    }

    func testDiagnosticLogPrunesExpiredPersistedEventsOnRelaunch()
        async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticRelaunchRetentionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialNow = Date(timeIntervalSince1970: 2_000_000_000)
        let writer = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            sessionID: "writer",
            nowProvider: { initialNow }
        )
        await writer.record(
            .photoScanProgress(
                processedCount: 1,
                targetCount: 1,
                analyzedCount: 1,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 100,
                isCompleteUpdate: true,
                at: initialNow
            )
        )

        let reloader = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            sessionID: "reloader",
            nowProvider: {
                initialNow.addingTimeInterval(8 * 24 * 60 * 60)
            }
        )

        let events = await reloader.storedEvents()
        XCTAssertTrue(events.isEmpty)
        let byteCount = (
            (
                try? FileManager.default.attributesOfItem(
                    atPath: fileURL.path
                )
            )?[.size] as? NSNumber
        )?.intValue
        XCTAssertEqual(byteCount, 0)
    }

    func testDiagnosticLogDropsFutureEventsAfterClockCorrection() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticClockCorrectionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let correctedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let futureNow = correctedNow.addingTimeInterval(8 * 24 * 60 * 60)
        let futureClockWriter = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            sessionID: "future",
            nowProvider: { futureNow }
        )
        await futureClockWriter.record(
            .photoScanProgress(
                processedCount: 99,
                targetCount: 100,
                analyzedCount: 99,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 99,
                isCompleteUpdate: false,
                at: futureNow
            )
        )

        let correctedClockStore = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            sessionID: "corrected",
            nowProvider: { correctedNow }
        )

        let correctedEvents = await correctedClockStore.storedEvents()
        XCTAssertTrue(correctedEvents.isEmpty)
        await correctedClockStore.record(
            .photoScanProgress(
                processedCount: 1,
                targetCount: 1,
                analyzedCount: 1,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 100,
                isCompleteUpdate: true,
                at: correctedNow
            )
        )
        let recoveredEvents = await correctedClockStore.storedEvents()
        XCTAssertEqual(
            recoveredEvents.compactMap { $0.fields["processed"] },
            ["1"]
        )
    }

    func testDiagnosticExportUsesCurrentSessionUptimeCutoff()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticCutoffTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoDuckDiagnosticLog(
            fileURL: fileURL,
            sessionID: "cutoff",
            exportDirectoryURL: directory
        )
        await store.record(
            .photoScanProgress(
                processedCount: 1,
                targetCount: 2,
                analyzedCount: 1,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 50,
                isCompleteUpdate: false
            )
        )
        let uptimeCutoff = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: 1_000_000)
        await store.record(
            .photoScanProgress(
                processedCount: 2,
                targetCount: 2,
                analyzedCount: 2,
                unanalyzedCount: 0,
                groupCount: 0,
                progressPercent: 100,
                isCompleteUpdate: true
            )
        )

        let reportURL = try await store.exportReport(
            snapshot: diagnosticSnapshot(),
            currentSessionUptimeCutoff: uptimeCutoff
        )
        let data = try Data(contentsOf: reportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(
            PhotoDuckDiagnosticReportEnvelope.self,
            from: data
        )
        XCTAssertEqual(
            report.events.compactMap { $0.fields["processed"] },
            ["1"]
        )
    }

    func testDiagnosticStartupMaintenanceRemovesOnlyStaleExports()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoDuckDiagnosticMaintenanceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let oldExport = directory.appendingPathComponent(
            "PhotoDuck-Diagnostics-old.json"
        )
        let recentExport = directory.appendingPathComponent(
            "PhotoDuck-Diagnostics-recent.json"
        )
        let unrelatedFile = directory.appendingPathComponent(
            "keep-me.json"
        )
        for url in [oldExport, recentExport, unrelatedFile] {
            try Data("{}".utf8).write(to: url)
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: oldExport.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: recentExport.path
        )
        let store = PhotoDuckDiagnosticLog(
            fileURL: directory.appendingPathComponent("events.jsonl"),
            sessionID: "maintenance",
            exportDirectoryURL: directory,
            nowProvider: { now }
        )

        await store.performStartupMaintenance(maximumExportAge: 3_600)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldExport.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recentExport.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedFile.path)
        )
    }

    private func candidate(
        _ kind: AssetResourceKind,
        _ filename: String,
        bytes: Int64?
    ) -> AssetResourceSizeCandidate {
        AssetResourceSizeCandidate(
            kind: kind,
            originalFilename: filename,
            byteCount: bytes
        )
    }

    private func imageRequestKey(
        intent: PhotoImageQualityIntent
    ) -> PhotoImageRequestKey {
        PhotoImageRequestKey(
            localIdentifier: "asset-1",
            modificationDate: Date(timeIntervalSince1970: 100),
            targetSize: CGSize(width: 144, height: 144),
            contentMode: .aspectFill,
            qualityIntent: intent,
            allowsNetworkAccess: false
        )
    }

    private func diagnosticSnapshot() -> PhotoDuckDiagnosticReportSnapshot {
        PhotoDuckDiagnosticReportSnapshot(
            generatedAt: Date(),
            appVersion: "1.0",
            buildVersion: "100",
            osVersion: "iOS test",
            deviceModel: "iPhone",
            photoAuthorization: "authorized",
            scanState: "scanning",
            cleanupMode: "deepClean",
            freshnessState: "live",
            isPaused: false,
            isFinalizingPhotoScan: false,
            isFinishingSupportingScans: true,
            libraryCount: 10,
            targetCount: 10,
            processedCount: 8,
            analyzedCount: 7,
            unanalyzedCount: 1,
            groupCount: 2,
            reviewableCount: 3,
            reclaimablePhotoBytes: 1_024,
            lastCompletedAt: nil,
            fileScanState: "scanning",
            videoTotalCount: 20,
            videoProcessedCount: 12,
            videoCacheHitCount: 10,
            qualifyingLargeVideoCount: 4,
            qualifyingLargeVideoBytes: 2_048,
            cachePersistenceHealthy: true,
            checkpoint: PhotoDuckDiagnosticCheckpointSummary(
                schemaVersion: 7,
                generation: 4,
                savedAt: Date(),
                libraryCount: 10,
                targetCount: 10,
                processedCount: 8,
                analyzedCount: 7,
                unanalyzedCount: 1,
                groupCount: 2,
                reviewableCount: 3,
                evaluatedIdentifierCount: 8,
                plannedIdentifierCount: 10,
                isComplete: false,
                isConsistent: true
            )
        )
    }
}

private final class ImageOperationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delayNanoseconds: UInt64
    private var starts = 0
    private var cancellations = 0

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    var startedCount: Int {
        lock.withLock { starts }
    }

    var cancelledCount: Int {
        lock.withLock { cancellations }
    }

    func makeImage() async -> UIImage? {
        lock.withLock { starts += 1 }
        return await withTaskCancellationHandler {
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                return UIImage(systemName: "photo")
            } catch {
                return nil
            }
        } onCancel: {
            lock.withLock { cancellations += 1 }
        }
    }
}

private final class ExternalExportTestAsset: PHAsset, @unchecked Sendable {
    private let identifier: String

    init(localIdentifier: String) {
        identifier = localIdentifier
        super.init()
    }

    override var localIdentifier: String {
        identifier
    }
}

private struct StubFileScanAssetProvider: FileScanAssetProviding, @unchecked Sendable {
    let assets: [PHAsset]

    func fetchVideoAssets() async -> [PHAsset] {
        assets
    }
}

private actor FileScanUpdateProbe {
    private var updates: [FileScanUpdate] = []

    func append(_ update: FileScanUpdate) {
        updates.append(update)
    }

    func values() -> [FileScanUpdate] {
        updates
    }
}

private actor FileScanAuthorizationRequestProbe {
    private var count = 0

    func request(returning status: PHAuthorizationStatus) -> PHAuthorizationStatus {
        count += 1
        return status
    }

    func requestCount() -> Int {
        count
    }
}
