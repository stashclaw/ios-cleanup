import SwiftUI
import Photos
@preconcurrency import AVFoundation

struct VideoCompressionView: View {
    let file: LargeFile
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPreset: VideoCompressionEngine.Preset = .p720
    @State private var compressionState: CompressionState = .idle
    @State private var compressionTask: Task<Void, Never>?
    @State private var estimatedOutputBytes: Int64?
    @State private var hasSavedCopy = false
    @State private var savedCopyAssetIdentifier: String?

    enum CompressionState {
        case idle
        case preparing(progress: Double?, message: String)
        case compressing(progress: Double)
        case saving
        case success(VideoCompressionEngine.ReplacementOutcome)
        case failed(message: String, canRetry: Bool)

        var isWorking: Bool {
            switch self {
            case .preparing, .compressing, .saving:
                return true
            case .idle, .success, .failed:
                return false
            }
        }

        var canCancel: Bool {
            switch self {
            case .preparing, .compressing:
                return true
            case .idle, .saving, .success, .failed:
                return false
            }
        }

        var isSaving: Bool {
            if case .saving = self { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    fileHeader
                    presetPicker
                    estimatedSizes
                    stateContent
                }
                .padding()
            }
            .navigationTitle("Compress Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(toolbarButtonTitle, action: handleToolbarAction)
                        .disabled(compressionState.isSaving)
                }
            }
        }
        // PhotoKit writes cannot be rolled back after they begin, so keep the result visible.
        .interactiveDismissDisabled(compressionState.isSaving)
        .onDisappear {
            compressionTask?.cancel()
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch compressionState {
        case .idle:
            compressButton
        case .preparing(let progress, let message):
            progressSection(progress: progress, message: message)
        case .compressing(let progress):
            progressSection(
                progress: progress,
                message: "\(Int(progress * 100))% - Compressing..."
            )
        case .saving:
            progressSection(progress: nil, message: "Saving to Photos...")
        case .success(let outcome):
            successBanner(outcome)
        case .failed(let message, let canRetry):
            errorSection(message, canRetry: canRetry)
        }
    }

    // MARK: - Subviews

    private var fileHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.title)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(file.formattedSize)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quality Preset")
                .font(.headline)
            ForEach(VideoCompressionEngine.Preset.allCases, id: \.self) { preset in
                Button {
                    selectedPreset = preset
                    estimatedOutputBytes = nil
                } label: {
                    HStack {
                        Image(systemName: selectedPreset == preset ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(.purple)
                        Text(preset.rawValue)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(estimatedLabel(for: preset))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(
                        selectedPreset == preset ? Color.purple.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
                .disabled(compressionState.isWorking)
            }
        }
    }

    private var estimatedSizes: some View {
        HStack {
            Label("Estimated output", systemImage: "doc.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let estimatedOutputBytes {
                Text(ByteCountFormatter.string(
                    fromByteCount: estimatedOutputBytes,
                    countStyle: .file
                ))
                .font(.subheadline.bold())
                .foregroundStyle(.purple)
            } else {
                Text("Calculated before export")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var compressButton: some View {
        Button(action: startCompression) {
            Label("Compress & Replace", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.purple)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(compressionTask != nil || hasSavedCopy)
    }

    private func progressSection(progress: Double?, message: String) -> some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress)
                    .tint(.purple)
                    .scaleEffect(x: 1, y: 2)
            } else {
                ProgressView()
                    .tint(.purple)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func successBanner(
        _ outcome: VideoCompressionEngine.ReplacementOutcome
    ) -> some View {
        let content = successContent(for: outcome)
        return VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.duckDisplay(56))
                .foregroundStyle(Color.success)
            Text(content.title)
                .font(.title2.bold())
            Text(content.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorSection(_ message: String, canRetry: Bool) -> some View {
        VStack(spacing: 12) {
            Text("Compression stopped")
                .font(.headline)
                .foregroundStyle(Color.danger)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if canRetry && !hasSavedCopy {
                Button("Retry", action: startCompression)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Compression

    private func startCompression() {
        guard compressionTask == nil,
              !hasSavedCopy,
              savedCopyAssetIdentifier == nil else { return }
        let asset = file.photoAsset

        // Change state synchronously so a second tap cannot enqueue another export.
        compressionState = .preparing(progress: nil, message: "Checking free space...")
        estimatedOutputBytes = nil
        compressionTask = Task {
            await runCompression(for: asset)
        }
    }

    @MainActor
    private func runCompression(for asset: PHAsset) async {
        let engine = VideoCompressionEngine()
        var pendingOutput: VideoCompressionEngine.CompressionOutput?
        defer { compressionTask = nil }

        do {
            _ = try VideoCompressionEngine.preflightSourceDownload(
                originalBytes: file.byteSize
            )
            try Task.checkCancellation()

            compressionState = .preparing(progress: nil, message: "Loading video...")
            let avAsset = try await loadAVAsset(for: asset) { progress in
                guard case .preparing = compressionState else { return }
                compressionState = .preparing(
                    progress: progress,
                    message: "Downloading from iCloud - \(Int(progress * 100))%"
                )
            }
            try Task.checkCancellation()

            for await event in engine.compress(
                asset: avAsset,
                preset: selectedPreset,
                originalBytes: file.byteSize,
                originalBytesAreEstimated: file.byteSizeIsEstimated
            ) {
                try Task.checkCancellation()
                switch event {
                case .prepared(let estimate):
                    estimatedOutputBytes = estimate.outputBytes
                    compressionState = .compressing(progress: 0)
                case .progress(let progress):
                    compressionState = .compressing(progress: progress)
                case .completed(let output):
                    pendingOutput = output
                    output.claimTemporaryFile()
                case .cancelled:
                    return
                case .failed(let error):
                    compressionState = .failed(
                        message: error.localizedDescription,
                        canRetry: error.isRetryable
                    )
                    return
                }
            }

            try Task.checkCancellation()
            guard let output = pendingOutput else {
                compressionState = .failed(
                    message: "No output file was produced.",
                    canRetry: true
                )
                return
            }

            compressionState = .saving
            let outcome = await engine.saveAndDeleteOriginal(
                compressedURL: output.url,
                originalAsset: asset
            )
            pendingOutput = nil

            switch outcome {
            case .failed(let message):
                compressionState = .failed(message: message, canRetry: true)
            case .savedAndDeleted, .savedButOriginalKept:
                hasSavedCopy = true
                savedCopyAssetIdentifier = outcome.savedAssetIdentifier
                compressionState = .success(outcome)
            }
        } catch is CancellationError {
            if let output = pendingOutput {
                await engine.discardTemporaryOutput(at: output.url)
            }
        } catch let error as CompressionError {
            compressionState = .failed(
                message: error.localizedDescription,
                canRetry: error.isRetryable
            )
        } catch {
            compressionState = .failed(
                message: error.localizedDescription,
                canRetry: true
            )
        }
    }

    private func handleToolbarAction() {
        if compressionState.canCancel {
            compressionTask?.cancel()
            dismiss()
        } else if !compressionState.isSaving {
            dismiss()
        }
    }

    private var toolbarButtonTitle: String {
        if case .success = compressionState { return "Done" }
        return "Cancel"
    }

    private func estimatedLabel(for preset: VideoCompressionEngine.Preset) -> String {
        guard preset == selectedPreset, let estimatedOutputBytes else {
            return "Analyze on start"
        }
        return ByteCountFormatter.string(
            fromByteCount: estimatedOutputBytes,
            countStyle: .file
        )
    }

    private func successContent(
        for outcome: VideoCompressionEngine.ReplacementOutcome
    ) -> (title: String, message: String) {
        switch outcome {
        case .savedAndDeleted:
            return (
                "Compressed & Saved",
                "The smaller copy keeps the original date and location. The original was moved to Recently Deleted."
            )
        case .savedButOriginalKept(_, let reason, _):
            return ("Compressed Copy Saved", reason)
        case .failed(let message):
            return ("Compression Stopped", message)
        }
    }

    private func loadAVAsset(
        for asset: PHAsset,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AVAsset {
        let manager = PHImageManager.default()
        let requestState = VideoAssetRequestState()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard requestState.install(continuation: continuation) else { return }

                let options = PHVideoRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                options.progressHandler = { value, _, _, _ in
                    let clampedValue = min(max(value, 0), 1)
                    Task { @MainActor in
                        progress(clampedValue)
                    }
                }

                let requestID = manager.requestAVAsset(
                    forVideo: asset,
                    options: options
                ) { avAsset, _, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        requestState.complete(.failure(error))
                    } else if (info?[PHImageCancelledKey] as? Bool) == true {
                        requestState.complete(.failure(CancellationError()))
                    } else if let avAsset {
                        requestState.complete(.success(avAsset))
                    } else {
                        requestState.complete(.failure(VideoAssetLoadingError.unavailable))
                    }
                }
                requestState.setRequestID(requestID, manager: manager)
            }
        } onCancel: {
            requestState.cancel(manager: manager)
        }

        guard let avAsset = requestState.asset else {
            throw VideoAssetLoadingError.unavailable
        }
        return avAsset
    }
}

private enum VideoAssetLoadingError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Could not load this video from Photos."
    }
}

private final class VideoAssetRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID = PHInvalidImageRequestID
    private var isFinished = false
    private var isCancelled = false
    private var storedAsset: AVAsset?

    var asset: AVAsset? {
        lock.lock()
        defer { lock.unlock() }
        return storedAsset
    }

    func install(continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ requestID: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            manager.cancelImageRequest(requestID)
        }
    }

    func complete(_ result: Result<AVAsset, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        switch result {
        case .success(let asset):
            storedAsset = asset
        case .failure:
            storedAsset = nil
        }
        lock.unlock()

        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func cancel(manager: PHImageManager) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isCancelled = true
        isFinished = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
        }
        continuation?.resume(throwing: CancellationError())
    }
}
