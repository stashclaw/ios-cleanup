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
                                DuckFileRow(
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

private struct DuckFileRow: View {
    let file: LargeFile
    let purchaseManager: PurchaseManager
    let onDelete: () -> Void
    let onCompress: () -> Void

    private var isVideo: Bool {
        if case .photoLibrary(let asset) = file.source { return asset.mediaType == .video }
        let ext = (file.displayName as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: isVideo ? "video.fill" : "doc.fill")
                    .font(.title3)
                    .foregroundStyle(isVideo ? Color.duckOrange : Color.duckPink)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName)
                        .font(.duckBody)
                        .foregroundStyle(Color.duckBerry)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(file.formattedSize)
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                        typeBadge
                        if let date = file.creationDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.duckLabel)
                                .foregroundStyle(Color.duckSoftPink)
                        }
                    }
                }
                Spacer()
            }

            HStack(spacing: 10) {
                DuckOutlineButton(title: "Delete", color: .duckRose, action: onDelete)
                if isVideo {
                    DuckPrimaryButton(
                        title: purchaseManager.isPurchased ? "Compress" : "Compress 🔒",
                        action: onCompress
                    )
                }
            }
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
}
