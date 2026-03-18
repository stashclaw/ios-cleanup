import XCTest
import AVFoundation
@testable import iOSCleanup

final class VideoCompressionEngineTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a short synthetic video (1 second, solid colour) in the temp directory.
    private func makeSyntheticVideo(duration: CMTime = CMTimeMake(value: 1, timescale: 1)) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_input_\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080,
            ]
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Write one frame
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        if let pb = pixelBuffer {
            adaptor.append(pb, withPresentationTime: .zero)
        }

        input.markAsFinished()
        await writer.finishWriting()

        XCTAssertEqual(writer.status, .completed, "Synthetic video writer should complete")
        return outputURL
    }

    // MARK: - Tests

    func testPresetSizeMultipliers() {
        XCTAssertLessThan(
            VideoCompressionEngine.Preset.p720.sizeMultiplier,
            VideoCompressionEngine.Preset.p1080.sizeMultiplier,
            "720p should have a smaller size multiplier than 1080p"
        )
        XCTAssertLessThan(
            VideoCompressionEngine.Preset.p1080.sizeMultiplier,
            VideoCompressionEngine.Preset.original.sizeMultiplier,
            "1080p should have a smaller multiplier than original"
        )
    }

    func testEstimatedOutputSize() {
        let originalBytes: Int64 = 200_000_000  // 200 MB
        let estimated = VideoCompressionEngine.Preset.p720.estimatedOutputBytes(originalBytes: originalBytes)
        XCTAssertLessThan(estimated, originalBytes, "720p estimate should be smaller than original")
        XCTAssertGreaterThan(estimated, 0)
    }

    func testCompressToLowerPresetProducesFile() async throws {
        let inputURL = try await makeSyntheticVideo()
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let asset = AVURLAsset(url: inputURL)
        let engine = VideoCompressionEngine()

        var lastProgress: Double = 0
        var outputURL: URL?

        let stream = engine.compress(asset: asset, preset: .p720)
        for await event in stream {
            switch event {
            case .progress(let p): lastProgress = p
            case .completed(let url): outputURL = url
            case .failed(let error): XCTFail("Compression failed: \(error)")
            }
        }

        XCTAssertNotNil(outputURL, "Output URL should be set after compression")
        if let url = outputURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Compressed file should exist")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes[.size] as? Int64 ?? 0
            XCTAssertGreaterThan(size, 0, "Compressed file should not be empty")
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertGreaterThan(lastProgress, 0, "Progress should have been reported")
    }
}
