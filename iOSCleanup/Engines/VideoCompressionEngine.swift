@preconcurrency import AVFoundation
import Photos

actor VideoCompressionEngine {

    // MARK: - Preset

    enum Preset: String, CaseIterable, Sendable {
        case p720    = "720p"
        case p1080   = "1080p"
        case original = "Original Quality"

        var avPreset: String {
            switch self {
            case .p720:    return AVAssetExportPreset1280x720
            case .p1080:   return AVAssetExportPreset1920x1080
            case .original: return AVAssetExportPresetHighestQuality
            }
        }

        /// Approximate fraction of original file size after compression
        var sizeMultiplier: Double {
            switch self {
            case .p720:    return 0.30
            case .p1080:   return 0.55
            case .original: return 0.90
            }
        }

        func estimatedOutputBytes(originalBytes: Int64) -> Int64 {
            Int64(Double(originalBytes) * sizeMultiplier)
        }
    }

    // MARK: - Stream events

    enum CompressionEvent: Sendable {
        case progress(Double)        // 0.0 – 1.0
        case completed(URL)          // temp URL of compressed file
        case failed(String)
    }

    // MARK: - Main entry point

    nonisolated func compress(asset: AVAsset, preset: Preset) -> AsyncStream<CompressionEvent> {
        AsyncStream { continuation in
            Task { [continuation] in
                do {
                    let outputURL = try await exportSession(asset: asset, preset: preset, continuation: continuation)
                    continuation.yield(.completed(outputURL))
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Export

    private nonisolated func exportSession(
        asset: AVAsset,
        preset: Preset,
        continuation: AsyncStream<CompressionEvent>.Continuation
    ) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset.avPreset) else {
            throw CompressionError.exportSessionUnavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed_\(UUID().uuidString).mp4")

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        // Poll progress — wrap session in unchecked-sendable box so the Task closure compiles
        // under complete strict concurrency (AVAssetExportSession is thread-safe in practice).
        struct SendableSession: @unchecked Sendable { let inner: AVAssetExportSession }
        let sendable = SendableSession(inner: session)
        let progressTask = Task { [continuation, sendable] in
            while !Task.isCancelled {
                let p = Double(sendable.inner.progress)
                continuation.yield(.progress(min(p, 0.99)))
                try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
            }
        }

        await session.export()
        progressTask.cancel()

        guard session.status == .completed else {
            throw session.error ?? CompressionError.exportFailed
        }

        continuation.yield(.progress(1.0))
        return outputURL
    }

    // MARK: - Save to photo library then delete original

    /// Saves compressed file to the photo library, then deletes the original PHAsset.
    /// Call this after `compress()` completes and the user confirms.
    func saveAndDeleteOriginal(compressedURL: URL, originalAsset: PHAsset) async throws {
        // 1. Save compressed video to photo library
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: compressedURL)
        }
        // 2. Delete original asset
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([originalAsset] as NSFastEnumeration)
        }
        // 3. Clean up temp file
        try? FileManager.default.removeItem(at: compressedURL)
    }
}

// MARK: - Errors

enum CompressionError: Error, LocalizedError {
    case exportSessionUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable: return "Could not create export session for this video."
        case .exportFailed: return "Video export failed."
        }
    }
}
