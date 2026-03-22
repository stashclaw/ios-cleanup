import SwiftUI
import Photos
@preconcurrency import AVFoundation

struct VideoCompressionView: View {
    let file: LargeFile
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPreset: VideoCompressionEngine.Preset = .p720
    @State private var compressionState: CompressionState = .idle
    @State private var compressedURL: URL?

    enum CompressionState {
        case idle
        case compressing(progress: Double)
        case success
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    fileHeader
                    presetPicker
                    estimatedSizes
                    switch compressionState {
                    case .idle:          compressButton
                    case .compressing:   progressSection
                    case .success:       successBanner
                    case .failed(let e): errorSection(e)
                    }
                }
                .padding()
            }
            .navigationTitle("Compress Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sub-views

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
                Button(action: { selectedPreset = preset }) {
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
                    .background(selectedPreset == preset ? Color.purple.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var estimatedSizes: some View {
        HStack {
            Label("Estimated output", systemImage: "doc.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(ByteCountFormatter.string(
                fromByteCount: selectedPreset.estimatedOutputBytes(originalBytes: file.byteSize),
                countStyle: .file
            ))
            .font(.subheadline.bold())
            .foregroundStyle(.purple)
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
    }

    private var currentProgress: Double {
        if case .compressing(let p) = compressionState { return p }
        return 0
    }

    private var progressSection: some View {
        VStack(spacing: 12) {
            ProgressView(value: currentProgress)
                .tint(.purple)
                .scaleEffect(x: 1, y: 2)
            Text("\(Int(currentProgress * 100))% — Compressing…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var successBanner: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Compressed & Saved!")
                .font(.title2.bold())
            Text("The compressed video has been saved to your library and the original deleted.")
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

    private func errorSection(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("Compression failed")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: startCompression)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Compression

    private func startCompression() {
        guard case .photoLibrary(let asset) = file.source else {
            compressionState = .failed("Filesystem video compression is not supported.")
            return
        }

        Task {
            // Load AVAsset from PHAsset
            guard let avAsset = await loadAVAsset(for: asset) else {
                compressionState = .failed("Could not load video asset.")
                return
            }

            let engine = VideoCompressionEngine()
            var outputURL: URL?

            for await event in engine.compress(asset: avAsset, preset: selectedPreset) {
                switch event {
                case .progress(let p):
                    compressionState = .compressing(progress: p)
                case .completed(let url):
                    outputURL = url
                case .failed(let msg):
                    compressionState = .failed(msg)
                    return
                }
            }

            guard let url = outputURL else {
                compressionState = .failed("No output file produced.")
                return
            }

            // Save to library and delete original
            do {
                try await engine.saveAndDeleteOriginal(compressedURL: url, originalAsset: asset)
                compressionState = .success
            } catch {
                compressionState = .failed(error.localizedDescription)
            }
        }
    }

    private func loadAVAsset(for asset: PHAsset) async -> AVAsset? {
        // Use a void continuation + @unchecked Sendable box to avoid sending AVAsset
        // across isolation under complete strict concurrency (AVAsset is thread-safe in practice).
        final class Box: @unchecked Sendable { var value: AVAsset? }
        let box = Box()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                box.value = avAsset
                continuation.resume()
            }
        }
        return box.value
    }

    private func estimatedLabel(for preset: VideoCompressionEngine.Preset) -> String {
        ByteCountFormatter.string(
            fromByteCount: preset.estimatedOutputBytes(originalBytes: file.byteSize),
            countStyle: .file
        )
    }
}
