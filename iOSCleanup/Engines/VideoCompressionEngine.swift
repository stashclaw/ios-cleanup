@preconcurrency import AVFoundation
import Foundation
import Photos

actor VideoCompressionEngine {

    // MARK: - Tuning

    enum Tuning {
        /// Leaves enough headroom for Photos and AVFoundation to finish their atomic writes.
        static let minimumFreeSpaceReserveBytes: Int64 = 128 * 1_024 * 1_024
        static let exportWorkingSpaceMultiplier = 1.20
        static let progressPollingNanoseconds: UInt64 = 200_000_000
    }

    // MARK: - Preset

    enum Preset: String, CaseIterable, Sendable {
        case p720 = "720p"
        case p1080 = "1080p"
        case original = "Original Quality"

        /// Ordered by preference. HEVC is used when AVFoundation reports it as compatible.
        var preferredAVPresets: [String] {
            switch self {
            case .p720:
                // AVFoundation does not provide an HEVC 720p export preset.
                return [AVAssetExportPreset1280x720]
            case .p1080:
                return [
                    AVAssetExportPresetHEVC1920x1080,
                    AVAssetExportPreset1920x1080,
                ]
            case .original:
                return [
                    AVAssetExportPresetHEVCHighestQuality,
                    AVAssetExportPresetHighestQuality,
                ]
            }
        }

        var targetPixelCount: Double? {
            switch self {
            case .p720:
                return 1_280 * 720
            case .p1080:
                return 1_920 * 1_080
            case .original:
                return nil
            }
        }
    }

    struct CompressionEstimate: Sendable, Equatable {
        let outputBytes: Int64
        let sourceBitsPerSecond: Double
        let sourcePixelCount: Double
        let exportPresetName: String
    }

    struct CompressionOutput: Sendable, Equatable {
        let url: URL
        let originalBytes: Int64
        let outputBytes: Int64
        let exportPresetName: String
        private let lease: VideoCompressionOutputLease

        fileprivate init(
            url: URL,
            originalBytes: Int64,
            outputBytes: Int64,
            exportPresetName: String,
            lease: VideoCompressionOutputLease
        ) {
            self.url = url
            self.originalBytes = originalBytes
            self.outputBytes = outputBytes
            self.exportPresetName = exportPresetName
            self.lease = lease
        }

        /// Transfers temp-file cleanup responsibility to the consumer.
        func claimTemporaryFile() {
            lease.claim()
        }

        static func == (lhs: CompressionOutput, rhs: CompressionOutput) -> Bool {
            lhs.url == rhs.url &&
                lhs.originalBytes == rhs.originalBytes &&
                lhs.outputBytes == rhs.outputBytes &&
                lhs.exportPresetName == rhs.exportPresetName
        }
    }

    enum CompressionEvent: Sendable, Equatable {
        case prepared(CompressionEstimate)
        case progress(Double)
        case completed(CompressionOutput)
        case cancelled
        case failed(CompressionError)
    }

    enum ReplacementOutcome: Sendable, Equatable {
        case savedAndDeleted(savedAssetIdentifier: String?)
        case savedButOriginalKept(
            savedAssetIdentifier: String?,
            reason: String,
            userCancelledDeletion: Bool
        )
        case failed(String)

        var savedAssetIdentifier: String? {
            switch self {
            case .savedAndDeleted(let identifier):
                return identifier
            case .savedButOriginalKept(let identifier, _, _):
                return identifier
            case .failed:
                return nil
            }
        }

        var didSaveCopy: Bool {
            switch self {
            case .savedAndDeleted, .savedButOriginalKept:
                return true
            case .failed:
                return false
            }
        }
    }

    // MARK: - Startup cleanup

    private static let startupSweep: Void = {
        _ = sweepOrphanedTemporaryFiles()
    }()

    init() {
        // This executes once per process before the first compression flow starts.
        _ = Self.startupSweep
    }

    nonisolated static func performStartupCleanup() {
        _ = startupSweep
    }

    /// Removes only files owned by this engine. The directory argument is a deterministic test seam.
    @discardableResult
    nonisolated static func sweepOrphanedTemporaryFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let orphans = urls.filter {
            $0.lastPathComponent.hasPrefix("compressed_") &&
                $0.pathExtension.lowercased() == "mp4"
        }
        for url in orphans {
            try? fileManager.removeItem(at: url)
        }
        return orphans
    }

    // MARK: - Capacity and estimates

    /// Preflights enough space for an iCloud source download plus export and atomic-write headroom.
    @discardableResult
    nonisolated static func preflightSourceDownload(
        originalBytes: Int64,
        availableCapacity: Int64? = availableTemporaryCapacity()
    ) throws -> Int64 {
        try validateDiskCapacity(
            originalBytes: originalBytes,
            estimatedOutputBytes: originalBytes,
            availableCapacity: availableCapacity
        )
    }

    @discardableResult
    nonisolated static func validateDiskCapacity(
        originalBytes: Int64,
        estimatedOutputBytes: Int64,
        availableCapacity: Int64?
    ) throws -> Int64 {
        let sourceBytes = max(0, originalBytes)
        let outputBytes = max(0, estimatedOutputBytes)
        let exportWorkingEstimate =
            (Double(outputBytes) * Tuning.exportWorkingSpaceMultiplier).rounded(.up)
        let exportWorkingBytes = exportWorkingEstimate >= Double(Int64.max)
            ? Int64.max
            : Int64(exportWorkingEstimate)
        let sourceAndExport = sourceBytes.addingReportingOverflow(exportWorkingBytes)
        let withReserve = sourceAndExport.partialValue.addingReportingOverflow(
            Tuning.minimumFreeSpaceReserveBytes
        )
        let requiredBytes = sourceAndExport.overflow || withReserve.overflow
            ? Int64.max
            : withReserve.partialValue

        if let availableCapacity, availableCapacity < requiredBytes {
            throw CompressionError.insufficientDiskSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableCapacity
            )
        }
        return requiredBytes
    }

    nonisolated static func validateOutputSize(
        originalBytes: Int64,
        outputBytes: Int64
    ) throws {
        guard outputBytes > 0 else {
            throw CompressionError.emptyOutput
        }
        guard originalBytes > 0 else {
            throw CompressionError.invalidOriginalSize
        }
        guard outputBytes < originalBytes else {
            throw CompressionError.outputNotSmaller(
                originalBytes: originalBytes,
                outputBytes: outputBytes
            )
        }
    }

    private nonisolated static func availableTemporaryCapacity() -> Int64? {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        if let values = try? temporaryDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }

        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: temporaryDirectory.path
        )
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private nonisolated static func estimate(
        asset: AVAsset,
        preset: Preset,
        originalBytes: Int64,
        exportPresetName: String
    ) async throws -> CompressionEstimate {
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw CompressionError.invalidSource
        }

        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let naturalSize = try await videoTrack?.load(.naturalSize) ?? .zero
        let preferredTransform = try await videoTrack?.load(.preferredTransform) ?? .identity
        let transformedSize = naturalSize.applying(preferredTransform)
        let sourcePixelCount = max(
            1,
            Double(abs(transformedSize.width) * abs(transformedSize.height))
        )
        let sourceBitsPerSecond = max(
            1,
            Double(originalBytes) * 8 / durationSeconds
        )

        let pixelRatio: Double
        if let targetPixelCount = preset.targetPixelCount {
            pixelRatio = min(1, targetPixelCount / sourcePixelCount)
        } else {
            pixelRatio = 1
        }
        let usesHEVC = exportPresetName.localizedCaseInsensitiveContains("hevc")
        let codecEfficiency = usesHEVC ? 0.68 : 0.88
        let estimatedRate = sourceBitsPerSecond * max(0.20, pixelRatio) * codecEfficiency
        let estimatedBytes = max(
            1,
            min(originalBytes, Int64((estimatedRate * durationSeconds / 8).rounded(.up)))
        )

        return CompressionEstimate(
            outputBytes: estimatedBytes,
            sourceBitsPerSecond: sourceBitsPerSecond,
            sourcePixelCount: sourcePixelCount,
            exportPresetName: exportPresetName
        )
    }

    // MARK: - Main entry point

    nonisolated func compress(
        asset: AVAsset,
        preset: Preset,
        originalBytes: Int64,
        originalBytesAreEstimated: Bool = false
    ) -> AsyncStream<CompressionEvent> {
        AsyncStream { continuation in
            let control = VideoCompressionCancellationController()
            let producer = Task {
                do {
                    try Task.checkCancellation()
                    let verifiedOriginalBytes = try Self.resolveOriginalBytes(
                        reportedBytes: originalBytes,
                        isEstimated: originalBytesAreEstimated,
                        localSourceURL: (asset as? AVURLAsset)?.url
                    )
                    let exportPresetName = try await Self.compatiblePresetName(
                        for: asset,
                        preset: preset
                    )
                    let estimate = try await Self.estimate(
                        asset: asset,
                        preset: preset,
                        originalBytes: verifiedOriginalBytes,
                        exportPresetName: exportPresetName
                    )
                    _ = try Self.validateDiskCapacity(
                        originalBytes: verifiedOriginalBytes,
                        estimatedOutputBytes: estimate.outputBytes,
                        availableCapacity: Self.availableTemporaryCapacity()
                    )
                    continuation.yield(.prepared(estimate))

                    let outputURL = try await Self.export(
                        asset: asset,
                        presetName: exportPresetName,
                        continuation: continuation,
                        control: control
                    )
                    let outputBytes = try Self.fileSize(at: outputURL)
                    do {
                        try Self.validateOutputSize(
                            originalBytes: verifiedOriginalBytes,
                            outputBytes: outputBytes
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: outputURL)
                        control.clearExport()
                        throw error
                    }

                    let output = CompressionOutput(
                        url: outputURL,
                        originalBytes: verifiedOriginalBytes,
                        outputBytes: outputBytes,
                        exportPresetName: exportPresetName,
                        lease: VideoCompressionOutputLease(control: control)
                    )
                    continuation.yield(.completed(output))
                    continuation.finish()
                } catch is CancellationError {
                    control.cancel()
                    continuation.yield(.cancelled)
                    continuation.finish()
                } catch let error as CompressionError {
                    control.cancel()
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch {
                    control.cancel()
                    continuation.yield(.failed(.exportFailed(error.localizedDescription)))
                    continuation.finish()
                }
            }
            control.install(producer: producer)

            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    control.cancel()
                }
            }
        }
    }

    nonisolated static func resolveOriginalBytes(
        reportedBytes: Int64,
        isEstimated: Bool,
        localSourceURL: URL?
    ) throws -> Int64 {
        if let localSourceURL, localSourceURL.isFileURL,
           let measuredBytes = try? fileSize(at: localSourceURL),
           measuredBytes > 0 {
            return measuredBytes
        }
        guard !isEstimated else {
            throw CompressionError.unverifiedOriginalSize
        }
        guard reportedBytes > 0 else {
            throw CompressionError.invalidOriginalSize
        }
        return reportedBytes
    }

    private nonisolated static func compatiblePresetName(
        for asset: AVAsset,
        preset: Preset
    ) async throws -> String {
        for name in preset.preferredAVPresets {
            let isCompatible = await AVAssetExportSession.compatibility(
                ofExportPreset: name,
                with: asset,
                outputFileType: .mp4
            )
            if isCompatible {
                return name
            }
        }
        throw CompressionError.exportSessionUnavailable
    }

    private nonisolated static func export(
        asset: AVAsset,
        presetName: String,
        continuation: AsyncStream<CompressionEvent>.Continuation,
        control: VideoCompressionCancellationController
    ) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw CompressionError.exportSessionUnavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed_\(UUID().uuidString).mp4")
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        control.register(session: session, outputURL: outputURL)

        let sendableSession = SendableExportSession(session)
        let progressTask = Task {
            while !Task.isCancelled {
                continuation.yield(.progress(min(Double(sendableSession.value.progress), 0.99)))
                try? await Task.sleep(nanoseconds: Tuning.progressPollingNanoseconds)
            }
        }
        defer { progressTask.cancel() }

        try await withTaskCancellationHandler {
            await session.export()
            try Task.checkCancellation()
        } onCancel: {
            control.cancel()
        }

        guard session.status == .completed else {
            if session.status == .cancelled {
                throw CancellationError()
            }
            throw CompressionError.exportFailed(
                session.error?.localizedDescription ?? "AVFoundation did not complete the export."
            )
        }

        continuation.yield(.progress(1))
        return outputURL
    }

    private nonisolated static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Save and delete

    /// A save failure is retryable. Once the copy is saved, deletion is reported separately and
    /// never throws the UI back into an export retry that could create another compressed copy.
    ///
    /// Documented exemption from the DeletionManager invariant: this delete is
    /// part of an atomic save-then-replace the user explicitly confirmed, and
    /// PhotoKit shows its own system confirmation for it. Routing it through
    /// the 10-second coalesced undo window would let an undo strand the saved
    /// copy alongside the original with no cleanup path.
    func saveAndDeleteOriginal(
        compressedURL: URL,
        originalAsset: PHAsset
    ) async -> ReplacementOutcome {
        defer { try? FileManager.default.removeItem(at: compressedURL) }

        let identifierBox = CreatedAssetIdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(
                    atFileURL: compressedURL
                )
                identifierBox.didCreateRequest = request != nil
                request?.creationDate = originalAsset.creationDate
                request?.location = originalAsset.location
                request?.isFavorite = originalAsset.isFavorite
                identifierBox.value = request?.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            return .failed("The compressed copy could not be saved: \(error.localizedDescription)")
        }

        guard identifierBox.didCreateRequest else {
            return .failed("Photos could not create a compressed copy. The original was left unchanged.")
        }

        let savedIdentifier = identifierBox.value
        guard savedIdentifier != nil else {
            return .savedButOriginalKept(
                savedAssetIdentifier: nil,
                reason: "The compressed copy may have been saved, but Photos did not return its identifier. The original was kept to prevent data loss.",
                userCancelledDeletion: false
            )
        }

        if Task.isCancelled {
            return .savedButOriginalKept(
                savedAssetIdentifier: savedIdentifier,
                reason: "Compressed copy saved. The original was kept because the operation was cancelled.",
                userCancelledDeletion: true
            )
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([originalAsset] as NSFastEnumeration)
            }
            return .savedAndDeleted(savedAssetIdentifier: savedIdentifier)
        } catch {
            return Self.outcomeAfterSavedCopy(
                savedAssetIdentifier: savedIdentifier,
                deleteError: error
            )
        }
    }

    nonisolated static func outcomeAfterSavedCopy(
        savedAssetIdentifier: String?,
        deleteError: Error
    ) -> ReplacementOutcome {
        let nsError = deleteError as NSError
        let userCancelled = nsError.domain == PHPhotosErrorDomain &&
            nsError.code == PHPhotosError.userCancelled.rawValue
        let reason = userCancelled
            ? "Compressed copy saved. The original was kept."
            : "Compressed copy saved, but the original could not be deleted: \(deleteError.localizedDescription)"

        return .savedButOriginalKept(
            savedAssetIdentifier: savedAssetIdentifier,
            reason: reason,
            userCancelledDeletion: userCancelled
        )
    }

    func discardTemporaryOutput(at url: URL) {
        guard url.lastPathComponent.hasPrefix("compressed_") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Cancellation ownership

/// Owns the producer, export session, and partial URL as one cancellable unit.
/// Internal visibility provides a deterministic seam for cancellation cleanup tests.
final class VideoCompressionCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var producer: Task<Void, Never>?
    private var cancelExport: (@Sendable () -> Void)?
    private var outputURL: URL?
    private var cancellationRequested = false

    func install(producer: Task<Void, Never>) {
        lock.lock()
        self.producer = producer
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel {
            producer.cancel()
        }
    }

    func register(session: AVAssetExportSession, outputURL: URL) {
        let sendableSession = SendableExportSession(session)
        register(outputURL: outputURL) {
            sendableSession.value.cancelExport()
        }
    }

    func register(
        outputURL: URL,
        cancelExport: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        self.cancelExport = cancelExport
        self.outputURL = outputURL
        let shouldCancel = cancellationRequested
        lock.unlock()

        if shouldCancel {
            cancelExport()
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    func clearExport() {
        lock.lock()
        cancelExport = nil
        outputURL = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let producer = producer
        let cancelExport = cancelExport
        let outputURL = outputURL
        self.cancelExport = nil
        self.outputURL = nil
        lock.unlock()

        producer?.cancel()
        cancelExport?()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }
}

private final class VideoCompressionOutputLease: @unchecked Sendable {
    private let lock = NSLock()
    private var control: VideoCompressionCancellationController?

    init(control: VideoCompressionCancellationController) {
        self.control = control
    }

    func claim() {
        lock.lock()
        let control = control
        self.control = nil
        lock.unlock()
        control?.clearExport()
    }

    deinit {
        lock.lock()
        let control = control
        self.control = nil
        lock.unlock()
        control?.cancel()
    }
}

private struct SendableExportSession: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}

private final class CreatedAssetIdentifierBox: @unchecked Sendable {
    var value: String?
    var didCreateRequest = false
}

// MARK: - Errors

enum CompressionError: Error, LocalizedError, Sendable, Equatable {
    case exportSessionUnavailable
    case exportFailed(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case outputNotSmaller(originalBytes: Int64, outputBytes: Int64)
    case emptyOutput
    case invalidOriginalSize
    case unverifiedOriginalSize
    case invalidSource

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable:
            return "This video cannot be exported with the selected quality."
        case .exportFailed(let reason):
            return "Video export failed. \(reason)"
        case .insufficientDiskSpace(let requiredBytes, let availableBytes):
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return "Not enough free space to compress safely. \(required) is needed; \(available) is available."
        case .outputNotSmaller(let originalBytes, let outputBytes):
            let original = ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file)
            let output = ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)
            return "The compressed file would not save space (\(output) vs. \(original)), so the original was left unchanged."
        case .emptyOutput:
            return "The export produced an empty file. The original was left unchanged."
        case .invalidOriginalSize:
            return "The original video size could not be verified, so it was left unchanged."
        case .unverifiedOriginalSize:
            return "The original video size is only an estimate. PhotoDuck could not verify that compression would save space, so the original was left unchanged."
        case .invalidSource:
            return "The video duration or dimensions could not be read."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .exportSessionUnavailable, .exportFailed:
            return true
        case .insufficientDiskSpace, .outputNotSmaller, .emptyOutput,
             .invalidOriginalSize, .unverifiedOriginalSize, .invalidSource:
            return false
        }
    }
}
