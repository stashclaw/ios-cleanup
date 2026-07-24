import Photos
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
