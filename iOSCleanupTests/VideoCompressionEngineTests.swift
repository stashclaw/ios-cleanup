import XCTest
import AVFoundation
import Photos
@testable import iOSCleanup

final class VideoCompressionEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeSyntheticVideo(frameCount: Int = 30) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_input_\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640,
            AVVideoHeightKey: 360,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 360,
            ]
        )

        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                await Task.yield()
            }

            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(
                nil,
                640,
                360,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
            guard let pixelBuffer else {
                XCTFail("Could not create a synthetic frame")
                break
            }
            XCTAssertTrue(adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: Int64(frame), timescale: 30)
            ))
        }

        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "Synthetic video writer should complete")
        return outputURL
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoCompressionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    // MARK: - Presets and estimates

    func testHEVCPresetsArePreferredWithSafeFallbacks() {
        XCTAssertEqual(
            VideoCompressionEngine.Preset.p1080.preferredAVPresets,
            [
                AVAssetExportPresetHEVC1920x1080,
                AVAssetExportPreset1920x1080,
            ]
        )
        XCTAssertEqual(
            VideoCompressionEngine.Preset.original.preferredAVPresets,
            [
                AVAssetExportPresetHEVCHighestQuality,
                AVAssetExportPresetHighestQuality,
            ]
        )
        XCTAssertEqual(
            VideoCompressionEngine.Preset.p720.preferredAVPresets,
            [AVAssetExportPreset1280x720]
        )
    }

    // MARK: - Disk and output safety

    func testDiskPreflightRejectsLowCapacity() {
        let originalBytes: Int64 = 100 * 1_024 * 1_024
        let estimatedOutputBytes: Int64 = 50 * 1_024 * 1_024
        let availableBytes: Int64 = 20 * 1_024 * 1_024

        XCTAssertThrowsError(
            try VideoCompressionEngine.validateDiskCapacity(
                originalBytes: originalBytes,
                estimatedOutputBytes: estimatedOutputBytes,
                availableCapacity: availableBytes
            )
        ) { error in
            guard case CompressionError.insufficientDiskSpace(
                let requiredBytes,
                let reportedAvailableBytes
            ) = error else {
                return XCTFail("Expected insufficientDiskSpace, got \(error)")
            }
            XCTAssertGreaterThan(requiredBytes, availableBytes)
            XCTAssertEqual(reportedAvailableBytes, availableBytes)
        }
    }

    func testDiskPreflightDoesNotInventFailureWhenCapacityCannotBeRead() throws {
        let requiredBytes = try VideoCompressionEngine.validateDiskCapacity(
            originalBytes: 100,
            estimatedOutputBytes: 50,
            availableCapacity: nil
        )
        XCTAssertGreaterThan(
            requiredBytes,
            VideoCompressionEngine.Tuning.minimumFreeSpaceReserveBytes
        )
    }

    func testDiskPreflightClampsOverflowInsteadOfTrapping() {
        XCTAssertThrowsError(
            try VideoCompressionEngine.validateDiskCapacity(
                originalBytes: Int64.max,
                estimatedOutputBytes: Int64.max,
                availableCapacity: Int64.max - 1
            )
        ) { error in
            guard case CompressionError.insufficientDiskSpace(let required, _) = error else {
                return XCTFail("Expected insufficientDiskSpace, got \(error)")
            }
            XCTAssertEqual(required, Int64.max)
        }
    }

    func testOutputMustBeNonemptyAndStrictlySmaller() throws {
        XCTAssertNoThrow(
            try VideoCompressionEngine.validateOutputSize(
                originalBytes: 1_000,
                outputBytes: 999
            )
        )
        XCTAssertThrowsError(
            try VideoCompressionEngine.validateOutputSize(
                originalBytes: 1_000,
                outputBytes: 1_000
            )
        ) { error in
            guard case CompressionError.outputNotSmaller = error else {
                return XCTFail("Expected outputNotSmaller, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try VideoCompressionEngine.validateOutputSize(
                originalBytes: 1_000,
                outputBytes: 0
            )
        ) { error in
            XCTAssertEqual(error as? CompressionError, .emptyOutput)
        }
    }

    func testLoadedFileSizeOverridesAReportedEstimate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data(repeating: 1, count: 321).write(to: sourceURL)

        let resolved = try VideoCompressionEngine.resolveOriginalBytes(
            reportedBytes: 9_999,
            isEstimated: true,
            localSourceURL: sourceURL
        )

        XCTAssertEqual(resolved, 321)
    }

    func testUnverifiableEstimatedSourceSizeBlocksReplacement() {
        XCTAssertThrowsError(
            try VideoCompressionEngine.resolveOriginalBytes(
                reportedBytes: 9_999,
                isEstimated: true,
                localSourceURL: nil
            )
        ) { error in
            XCTAssertEqual(error as? CompressionError, .unverifiedOriginalSize)
        }
    }

    func testSafetyFailuresDoNotOfferBlindRetry() {
        XCTAssertFalse(
            CompressionError.outputNotSmaller(
                originalBytes: 100,
                outputBytes: 101
            ).isRetryable
        )
        XCTAssertFalse(
            CompressionError.insufficientDiskSpace(
                requiredBytes: 100,
                availableBytes: 50
            ).isRetryable
        )
        XCTAssertFalse(CompressionError.unverifiedOriginalSize.isRetryable)
        XCTAssertTrue(CompressionError.exportFailed("transient").isRetryable)
    }

    // MARK: - Cleanup and cancellation

    func testOrphanSweepRemovesOnlyOwnedCompressedMP4Files() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let orphan = directory.appendingPathComponent("compressed_orphan.mp4")
        let unrelatedVideo = directory.appendingPathComponent("vacation.mp4")
        let unrelatedPartial = directory.appendingPathComponent("compressed_notes.txt")
        try Data([1]).write(to: orphan)
        try Data([2]).write(to: unrelatedVideo)
        try Data([3]).write(to: unrelatedPartial)

        let removed = VideoCompressionEngine.sweepOrphanedTemporaryFiles(in: directory)

        XCTAssertEqual(removed.map(\.lastPathComponent), [orphan.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPartial.path))
    }

    func testCancellationStopsProducerAndDeletesPartialOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partialOutput = directory.appendingPathComponent("compressed_partial.mp4")
        try Data([1, 2, 3]).write(to: partialOutput)

        let cancellationFlag = LockedFlag()
        let producer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let controller = VideoCompressionCancellationController()
        controller.install(producer: producer)
        controller.register(outputURL: partialOutput) {
            cancellationFlag.set()
        }

        controller.cancel()

        XCTAssertTrue(producer.isCancelled)
        XCTAssertTrue(cancellationFlag.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialOutput.path))
    }

    func testCancellationBeforeExportRegistrationStillCancelsAndCleans() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partialOutput = directory.appendingPathComponent("compressed_race.mp4")
        try Data([1]).write(to: partialOutput)

        let cancellationFlag = LockedFlag()
        let controller = VideoCompressionCancellationController()
        controller.cancel()
        controller.register(outputURL: partialOutput) {
            cancellationFlag.set()
        }

        XCTAssertTrue(cancellationFlag.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialOutput.path))
    }

    // MARK: - Save/delete outcome separation

    func testUserCancelledDeletionReportsSavedCopyAndKeepsOriginal() {
        let error = NSError(
            domain: PHPhotosErrorDomain,
            code: PHPhotosError.userCancelled.rawValue
        )

        let outcome = VideoCompressionEngine.outcomeAfterSavedCopy(
            savedAssetIdentifier: "saved-copy-id",
            deleteError: error
        )

        guard case .savedButOriginalKept(
            let identifier,
            _,
            let userCancelledDeletion
        ) = outcome else {
            return XCTFail("A deletion cancellation must not report compression failure")
        }
        XCTAssertEqual(identifier, "saved-copy-id")
        XCTAssertTrue(userCancelledDeletion)
        XCTAssertTrue(outcome.didSaveCopy)
    }

    func testOtherDeletionFailureStillDoesNotOfferExportRetry() {
        let outcome = VideoCompressionEngine.outcomeAfterSavedCopy(
            savedAssetIdentifier: "saved-copy-id",
            deleteError: NSError(domain: "test", code: 1)
        )

        guard case .savedButOriginalKept(
            let identifier,
            _,
            let userCancelledDeletion
        ) = outcome else {
            return XCTFail("A saved copy must remain a success even if deletion fails")
        }
        XCTAssertEqual(identifier, "saved-copy-id")
        XCTAssertFalse(userCancelledDeletion)
        XCTAssertTrue(outcome.didSaveCopy)
    }

    // MARK: - AVFoundation smoke test

    func testCompressProducesValidatedFileAndProgress() async throws {
        let inputURL = try await makeSyntheticVideo()
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let actualInputBytes = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? NSNumber)?
                .int64Value
        )
        // The safety policy needs the PhotoKit source size. Give this synthetic fixture realistic
        // headroom so encoder-container overhead does not make a tiny black clip look "larger."
        let reportedOriginalBytes = max(actualInputBytes * 100, 25 * 1_024 * 1_024)
        let engine = VideoCompressionEngine()
        var lastProgress = 0.0
        var output: VideoCompressionEngine.CompressionOutput?
        var receivedEstimate = false

        for await event in engine.compress(
            asset: AVURLAsset(url: inputURL),
            preset: .p720,
            originalBytes: reportedOriginalBytes
        ) {
            switch event {
            case .prepared(let estimate):
                receivedEstimate = true
                XCTAssertGreaterThan(estimate.outputBytes, 0)
                XCTAssertFalse(estimate.exportPresetName.isEmpty)
            case .progress(let progress):
                lastProgress = progress
            case .completed(let completedOutput):
                output = completedOutput
                completedOutput.claimTemporaryFile()
            case .cancelled:
                XCTFail("Compression was unexpectedly cancelled")
            case .failed(let error):
                XCTFail("Compression failed: \(error.localizedDescription)")
            }
        }

        let completedOutput = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: completedOutput.url) }
        XCTAssertTrue(receivedEstimate)
        XCTAssertEqual(lastProgress, 1, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedOutput.url.path))
        XCTAssertGreaterThan(completedOutput.outputBytes, 0)
        XCTAssertLessThan(completedOutput.outputBytes, completedOutput.originalBytes)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
