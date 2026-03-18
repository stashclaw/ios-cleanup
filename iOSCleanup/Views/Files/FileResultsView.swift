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
                EmptyStateView(title: "No Large Files", icon: "doc.fill", message: "No files or videos over 50 MB were found.")
            } else {
                List(visibleFiles) { file in
                    FileRow(
                        file: file,
                        purchaseManager: purchaseManager,
                        onDelete: { Task { await deleteFile(file) } },
                        onCompress: {
                            guard purchaseManager.isPurchased else { showPaywall = true; return }
                            compressionTarget = file
                        }
                    )
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Large Files")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $compressionTarget) { file in
            VideoCompressionView(file: file)
                .environmentObject(purchaseManager)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
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

    private var isVideo: Bool {
        if case .photoLibrary(let asset) = file.source {
            return asset.mediaType == .video
        }
        let ext = (file.displayName as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isVideo ? "video.fill" : "doc.fill")
                    .font(.title3)
                    .foregroundStyle(isVideo ? .purple : .blue)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(file.formattedSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        typeBadge
                        if let date = file.creationDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if isVideo {
                    Button(action: onCompress) {
                        Label(
                            purchaseManager.isPurchased ? "Compress" : "Compress 🔒",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.purple.opacity(0.1))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var typeBadge: some View {
        Text(isVideo ? "Video" : "File")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isVideo ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15))
            .foregroundStyle(isVideo ? .purple : .blue)
            .clipShape(Capsule())
    }
}
