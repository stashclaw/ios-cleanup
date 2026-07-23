import Photos
import SwiftUI

enum FileDeletionErrorPolicy {
    static func isBenignCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain
            && nsError.code == PHPhotosError.Code.userCancelled.rawValue
    }
}

struct FileResultsView: View {
    let files: [LargeFile]
    let onRefresh: (() async -> Void)?

    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var compressionTarget: LargeFile?
    @State private var showPaywall = false
    @State private var deletionError: String?
    @State private var hiddenFileIDs = Set<UUID>()
    @State private var pendingPhotoFileIDs = Set<UUID>()

    init(files: [LargeFile], onRefresh: (() async -> Void)? = nil) {
        self.files = files
        self.onRefresh = onRefresh
    }

    private var visibleFiles: [LargeFile] {
        files.filter { !hiddenFileIDs.contains($0.id) }
    }

    var body: some View {
        refreshableContent
            .navigationTitle("Large Files")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $compressionTarget) { file in
                VideoCompressionView(file: file).environmentObject(purchaseManager)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView().environmentObject(purchaseManager)
            }
            .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
                showPaywall = false
            }
            .onChange(of: Set(files.map(\.id))) { availableIDs in
                // Parent data remains authoritative. Once a refresh removes an
                // item, discard its local optimistic-hide marker.
                hiddenFileIDs.formIntersection(availableIDs)
                pendingPhotoFileIDs.formIntersection(availableIDs)
            }
            .onChange(of: deletionManager.undoEventID) { _ in
                restoreUndonePhotoLibraryFiles()
            }
            .onChange(of: deletionManager.lastDeletionError) { error in
                guard error != nil else { return }
                hiddenFileIDs.subtract(pendingPhotoFileIDs)
                pendingPhotoFileIDs.removeAll()
            }
            .onChange(of: deletionManager.lastCommittedToastID) { toastID in
                guard toastID != nil else { return }
                pendingPhotoFileIDs.removeAll()
            }
    }

    @ViewBuilder
    private var refreshableContent: some View {
        if let onRefresh {
            resultsContent
                .refreshable {
                    await onRefresh()
                }
        } else {
            resultsContent
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if visibleFiles.isEmpty {
            ScrollView {
                EmptyStateView(
                    title: "No Large Files",
                    icon: "doc.fill",
                    message: "No files or videos over 50 MB were found."
                )
                .frame(maxWidth: .infinity)
            }
            .background(Color.duckBlush.ignoresSafeArea())
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    if let error = deletionError {
                        Text(error)
                            .font(.duckCaption)
                            .foregroundStyle(Color.danger)
                            .padding(.horizontal)
                    }
                    ForEach(visibleFiles) { file in
                        DuckCard {
                            FileRow(
                                file: file,
                                purchaseManager: purchaseManager,
                                onDelete: { requestDeletion(of: file) },
                                onCompress: {
                                    guard purchaseManager.isPurchased else {
                                        showPaywall = true
                                        return
                                    }
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

    private func requestDeletion(of file: LargeFile) {
        deletionError = nil
        hiddenFileIDs.insert(file.id)
        pendingPhotoFileIDs.insert(file.id)
        Task { await deletePhotoLibraryFile(file, asset: file.photoAsset) }
    }

    private func deletePhotoLibraryFile(_ file: LargeFile, asset: PHAsset) async {
        do {
            // The manager owns serialization, undo timing, confirmation, and
            // aggregate freed-byte accounting.
            try await deletionManager.delete(assets: [asset])
        } catch {
            hiddenFileIDs.remove(file.id)
            pendingPhotoFileIDs.remove(file.id)
            guard !FileDeletionErrorPolicy.isBenignCancellation(error) else { return }
            deletionError = error.localizedDescription
        }
    }

    private func restoreUndonePhotoLibraryFiles() {
        let undoneAssetIDs = deletionManager.lastUndoneAssetIDs
        guard !undoneAssetIDs.isEmpty else { return }

        let fileIDsToRestore = files.reduce(into: Set<UUID>()) { result, file in
            guard undoneAssetIDs.contains(file.photoAsset.localIdentifier) else {
                return
            }
            result.insert(file.id)
        }
        hiddenFileIDs.subtract(fileIDsToRestore)
        pendingPhotoFileIDs.subtract(fileIDsToRestore)
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
        file.photoAsset.mediaType == .video
    }

    private var photoAsset: PHAsset? {
        file.photoAsset
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView

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

                HStack(spacing: 8) {
                    if isVideo {
                        Button(action: onCompress) {
                            HStack(spacing: 4) {
                                Text("Compress")
                                if !purchaseManager.isPurchased {
                                    Image(systemName: "lock.fill")
                                }
                            }
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
            thumbnail = await asset.loadImage(
                targetSize: CGSize(width: 240, height: 240),
                deliveryMode: .opportunistic,
                allowNetwork: true,
                contentMode: .aspectFill,
                acceptsDegradedResult: true
            )
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
            Text(file.byteSizeIsEstimated ? "~\(formatted.number)" : formatted.number)
                .font(.duckBody(20, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(Color.duckPink)
            Text(formatted.unit)
                .font(.duckCaption.weight(.medium))
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
}
