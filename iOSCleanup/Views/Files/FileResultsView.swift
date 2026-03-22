import SwiftUI
import Photos

struct FileResultsView: View {
    let files: [LargeFile]
    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var compressionTarget: LargeFile?
    @State private var showPaywall = false
    @State private var deletionError: String?
    @State private var deletedIDs = Set<UUID>()

    private var visibleFiles: [LargeFile] {
        files.filter { !deletedIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if visibleFiles.isEmpty {
                EmptyStateView(title: "No Large Files", icon: "doc.fill",
                               message: "No files or videos over 50 MB were found.")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if let error = deletionError {
                            Text(error).font(.duckCaption).foregroundStyle(.red).padding(.horizontal)
                        }
                        ForEach(visibleFiles) { file in
                            DuckCard {
                                FileRow(
                                    file: file,
                                    purchaseManager: purchaseManager,
                                    onDelete: { Task { await deleteFile(file) } },
                                    onCompress: {
                                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                                        compressionTarget = file
                                    }
                                )
                                .padding(14)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .background(Color.duckBlush.ignoresSafeArea())
            }
        }
        .navigationTitle("Large Files")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $compressionTarget) { file in
            VideoCompressionView(file: file).environmentObject(purchaseManager)
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    private func deleteFile(_ file: LargeFile) async {
        switch file.source {
        case .photoLibrary(let asset):
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
                }
                deletedIDs.insert(file.id)
            } catch {
                deletionError = error.localizedDescription
            }
        case .filesystem(let url):
            do {
                try FileManager.default.removeItem(at: url)
                deletedIDs.insert(file.id)
            } catch {
                deletionError = error.localizedDescription
            }
        }
    }
}

// MARK: - File Row

private struct FileRow: View {
    let file: LargeFile
    let purchaseManager: PurchaseManager
    let onDelete: () -> Void
    let onCompress: () -> Void

    @State private var thumbnail: UIImage?

    private var isVideo: Bool {
        if case .photoLibrary(let asset) = file.source { return asset.mediaType == .video }
        let ext = (file.displayName as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    private var photoAsset: PHAsset? {
        if case .photoLibrary(let asset) = file.source { return asset }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail or icon
            thumbnailView

            // Info
            VStack(alignment: .leading, spacing: 6) {
                Text(file.displayName)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.duckBerry)
                    .lineLimit(2)

                fileSizeView

                HStack(spacing: 6) {
                    typeBadge
                    if let date = file.creationDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.duckLabel)
                            .foregroundStyle(Color.duckSoftPink)
                    }
                }

                // Pill buttons
                HStack(spacing: 8) {
                    if isVideo {
                        Button(action: onCompress) {
                            Text(purchaseManager.isPurchased ? "Compress" : "Compress 🔒")
                                .font(.duckLabel.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.duckPink, in: Capsule())
                        }
                    }
                    Button(action: onDelete) {
                        Text("Delete")
                            .font(.duckLabel.weight(.semibold))
                            .foregroundStyle(Color.duckRose)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.duckCream, in: Capsule())
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .task {
            guard let asset = photoAsset, isVideo else { return }
            thumbnail = await loadThumbnail(asset)
        }
    }

    private var thumbnailView: some View {
        Group {
            if let img = thumbnail {
                ZStack(alignment: .bottomTrailing) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isVideo ? Color.duckOrange.opacity(0.15) : Color.duckPink.opacity(0.15))
                    Image(systemName: isVideo ? "video.fill" : "doc.fill")
                        .font(.title2)
                        .foregroundStyle(isVideo ? Color.duckOrange : Color.duckPink)
                }
                .frame(width: 120, height: 120)
            }
        }
    }

    private var fileSizeView: some View {
        let formatted = splitSize(file.byteSize)
        return HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(formatted.number)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.duckPink)
            Text(formatted.unit)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.duckRose)
        }
    }

    private func splitSize(_ bytes: Int64) -> (number: String, unit: String) {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1 {
            return (String(format: "%.1f", gb), "GB")
        } else {
            return (String(format: "%.0f", mb), "MB")
        }
    }

    private var typeBadge: some View {
        Text(isVideo ? "Video" : "File")
            .font(.duckLabel)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isVideo ? Color.duckOrange.opacity(0.15) : Color.duckPink.opacity(0.15))
            .foregroundStyle(isVideo ? Color.duckOrange : Color.duckPink)
            .clipShape(Capsule())
    }

    private func loadThumbnail(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 240, height: 240),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }
}
