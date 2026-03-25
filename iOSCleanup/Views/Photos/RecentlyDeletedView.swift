import SwiftUI
import Photos

struct RecentlyDeletedView: View {
    @ObservedObject var viewModel: HomeViewModel
    @State private var isEmptying = false
    @State private var emptyError: String?
    @State private var showConfirm = false
    @State private var deletedIDs: Set<String> = []

    private let bg     = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let accent = Color(red: 1, green: 0.42, blue: 0.67)

    // 3 columns, 2pt gaps, full bleed
    private let gap: CGFloat = 2
    private var cellSize: CGFloat { (UIScreen.main.bounds.width - gap * 2) / 3 }

    private var visibleAssets: [PHAsset] {
        viewModel.recentlyDeletedPhotos.filter { !deletedIDs.contains($0.localIdentifier) }
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            Group {
                if visibleAssets.isEmpty && viewModel.recentlyDeletedScanState != .scanning {
                    emptyState
                } else {
                    contentView
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash.slash")
                .font(.system(size: 52))
                .foregroundStyle(Color.white.opacity(0.2))
            Text("Recently Deleted is Empty")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Photos you delete stay here for 30 days before being permanently removed.")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroCard
                    .padding(.horizontal, 16)
                if let error = emptyError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
                photoGrid
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(visibleAssets.count) item\(visibleAssets.count == 1 ? "" : "s")")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    if viewModel.recentlyDeletedBytes > 0 {
                        Text(ByteCountFormatter.string(
                            fromByteCount: viewModel.recentlyDeletedBytes,
                            countStyle: .file) + " will be freed")
                            .font(.system(size: 14))
                            .foregroundStyle(accent)
                    }
                }
                Spacer()
                Button { showConfirm = true } label: {
                    HStack(spacing: 6) {
                        if isEmptying {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        } else {
                            Image(systemName: "trash.fill")
                        }
                        Text(isEmptying ? "Emptying…" : "Empty Trash")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isEmptying || visibleAssets.isEmpty)
            }

            Text("Long-press any photo to delete it individually. Tap \"Empty Trash\" to permanently remove all items and reclaim space.")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(white: 1, opacity: 0.08)))
        .confirmationDialog(
            "Empty Recently Deleted?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(visibleAssets.count) Items Permanently", role: .destructive) {
                Task { await emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Photo grid (fixed-size cells, edge-to-edge)

    private var photoGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: gap), count: 3)
        return LazyVGrid(columns: columns, spacing: gap) {
            ForEach(visibleAssets, id: \.localIdentifier) { asset in
                RDCell(asset: asset, cellSize: cellSize)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await deleteOne(asset) }
                        } label: {
                            Label("Delete Permanently", systemImage: "trash.fill")
                        }
                    }
            }
        }
    }

    // MARK: - Actions

    private func emptyTrash() async {
        isEmptying = true
        emptyError = nil
        do {
            try await viewModel.emptyRecentlyDeleted()
            deletedIDs = []
        } catch {
            emptyError = error.localizedDescription
        }
        isEmptying = false
    }

    private func deleteOne(_ asset: PHAsset) async {
        let bytes = PHAssetResource.assetResources(for: asset)
            .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            deletedIDs.insert(asset.localIdentifier)
            if bytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil, userInfo: ["bytes": bytes]
                )
            }
        } catch {
            emptyError = error.localizedDescription
        }
    }
}

// MARK: - Self-loading cell

private struct RDCell: View {
    let asset: PHAsset
    let cellSize: CGFloat

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(white: 1, opacity: 0.06)
                        .overlay(ProgressView().scaleEffect(0.5).tint(.white))
                }
            }
            .frame(width: cellSize, height: cellSize)
            .clipped()

            if asset.mediaType == .video {
                Text(durationText(asset.duration))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .frame(width: cellSize, height: cellSize)
        .onAppear { load() }
        .onDisappear { cancel() }
    }

    private func load() {
        guard thumbnail == nil else { return }
        let scale = UIScreen.main.scale
        let px = cellSize * scale
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = false
        opts.resizeMode = .fast
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: px, height: px),
            contentMode: .aspectFill,
            options: opts
        ) { image, info in
            guard let image else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            Task { @MainActor in
                if thumbnail == nil || !degraded { thumbnail = image }
            }
        }
    }

    private func cancel() {
        if let id = requestID {
            PHImageManager.default().cancelImageRequest(id)
            requestID = nil
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return m > 0 ? "\(m):\(String(format: "%02d", s))" : "0:\(String(format: "%02d", s))"
    }
}
