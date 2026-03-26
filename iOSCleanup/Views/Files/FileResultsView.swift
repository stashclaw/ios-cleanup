import AVFoundation
import SwiftUI
import Photos

struct FileResultsView: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var homeViewModel: HomeViewModel

    @State private var compressionTarget: LargeFile?
    @State private var showPaywall = false
    @State private var deletionError: String?
    @State private var deletedIDs = Set<UUID>()
    @State private var thumbnails: [UUID: UIImage] = [:]

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)

    private var visibleFiles: [LargeFile] {
        homeViewModel.largeFiles.filter { !deletedIDs.contains($0.id) }
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            Group {
                if visibleFiles.isEmpty && homeViewModel.fileScanState != .scanning {
                    emptyState
                } else {
                    contentList
                }
            }
        }
        .navigationTitle("Large Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: $compressionTarget) { file in
            VideoCompressionView(file: file).environmentObject(purchaseManager)
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.white.opacity(0.2))
            Text("No Large Files")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("No files or videos over 50 MB were found.")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var contentList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if homeViewModel.fileScanState == .scanning {
                    ScanningBanner(message: "Finding large files…", color: Color(red: 0.2, green: 0.83, blue: 0.6))
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                // Summary header
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                if let error = deletionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                LazyVStack(spacing: 1) {
                    ForEach(visibleFiles) { file in
                        FileRow(
                            file: file,
                            thumbnail: thumbnails[file.id],
                            isPurchased: purchaseManager.isPurchased,
                            onDelete: { Task { await deleteFile(file) } },
                            onCompress: {
                                guard purchaseManager.isPurchased else { showPaywall = true; return }
                                compressionTarget = file
                            }
                        )
                        .onAppear { loadThumbnail(for: file) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private var summaryHeader: some View {
        HStack {
            Text("\(visibleFiles.count) items")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            let totalBytes = visibleFiles.reduce(Int64(0)) { $0 + $1.byteSize }
            Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                .font(.system(size: 14))
                .foregroundStyle(Color(red: 0.2, green: 0.83, blue: 0.6))
        }
    }

    // MARK: - Actions

    private func deleteFile(_ file: LargeFile) async {
        switch file.source {
        case .photoLibrary(let asset):
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
                }
                deletedIDs.insert(file.id)
                NotificationCenter.default.post(
                    name: .didFreeBytes,
                    object: nil,
                    userInfo: ["bytes": file.byteSize]
                )
            } catch { deletionError = error.localizedDescription }
        case .filesystem(let url):
            do {
                try FileManager.default.removeItem(at: url)
                deletedIDs.insert(file.id)
                NotificationCenter.default.post(
                    name: .didFreeBytes,
                    object: nil,
                    userInfo: ["bytes": file.byteSize]
                )
            } catch { deletionError = error.localizedDescription }
        }
    }

    private func loadThumbnail(for file: LargeFile) {
        guard thumbnails[file.id] == nil else { return }
        switch file.source {
        case .photoLibrary(let asset):
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 160, height: 160),
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                guard let img else { return }
                Task { @MainActor in self.thumbnails[file.id] = img }
            }
        case .filesystem(let url):
            let ext = url.pathExtension.lowercased()
            guard ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext) else { return }
            let fileID = file.id
            Task.detached(priority: .utility) {
                let asset = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 320)
                let time = CMTime(seconds: 1, preferredTimescale: 600)
                guard let cgImage = try? gen.copyCGImage(at: time, actualTime: nil) else { return }
                let img = UIImage(cgImage: cgImage)
                await MainActor.run { self.thumbnails[fileID] = img }
            }
        }
    }
}

// MARK: - File Row

private struct FileRow: View {
    let file: LargeFile
    let thumbnail: UIImage?
    let isPurchased: Bool
    let onDelete: () -> Void
    let onCompress: () -> Void

    @State private var showActions = false

    private var isVideo: Bool {
        if case .photoLibrary(let asset) = file.source { return asset.mediaType == .video }
        let ext = (file.displayName as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    private var duration: TimeInterval? {
        guard case .photoLibrary(let asset) = file.source, asset.mediaType == .video else { return nil }
        return asset.duration
    }

    private let accentGreen = Color(red: 0.2, green: 0.83, blue: 0.6)
    private let accentPink  = Color(red: 1, green: 0.42, blue: 0.67)

    var body: some View {
        VStack(spacing: 0) {
            Button { showActions.toggle() } label: {
                rowContent
            }
            .buttonStyle(.plain)

            if showActions {
                actionBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color(white: 1, opacity: 0.05))
        .animation(.easeInOut(duration: 0.2), value: showActions)
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            // Thumbnail / icon
            thumbnailView
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(file.formattedSize)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentGreen)

                    if let dur = duration {
                        Text(durationText(dur))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }

                    typeBadge
                }

                if let date = file.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }

            Spacer()

            Image(systemName: showActions ? "chevron.up" : "chevron.down")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let img = thumbnail {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                if let dur = duration {
                    Text(durationText(dur))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 1, opacity: 0.08))
                .overlay(
                    Image(systemName: isVideo ? "video.fill" : "doc.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(isVideo ? accentGreen : accentPink)
                )
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(white: 1, opacity: 0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if isVideo {
                Button(action: onCompress) {
                    Label(isPurchased ? "Compress" : "Compress 🔒",
                          systemImage: "arrow.down.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(accentGreen.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var typeBadge: some View {
        Text(isVideo ? "Video" : "File")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isVideo ? accentGreen.opacity(0.15) : accentPink.opacity(0.15))
            .foregroundStyle(isVideo ? accentGreen : accentPink)
            .clipShape(Capsule())
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return m > 0 ? "\(m):\(String(format: "%02d", s))" : "0:\(String(format: "%02d", s))"
    }
}
