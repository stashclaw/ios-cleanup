import Photos
import SwiftUI

// MARK: - Thumbnail cache (file-level, avoids NSCache generic restriction)

private let _semanticCellCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 300
    c.totalCostLimit = 40 * 1024 * 1024
    return c
}()

// MARK: - SemanticResultsView

struct SemanticResultsView: View {
    let group: SemanticGroup

    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var selectedIDs   = Set<String>()
    @State private var deletedIDs    = Set<String>()
    @State private var visibleCount  = 60
    @State private var isDeleting    = false
    @State private var deleteError:  String?
    @State private var showPaywall   = false

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var visibleAssets: [PHAsset] {
        group.assets.filter { !deletedIDs.contains($0.localIdentifier) }
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            if visibleAssets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color(red: 0.29, green: 0.85, blue: 0.6))
                    Text("All cleared!")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else {
                ScrollView {
                    photoGrid
                        .padding(.bottom, selectedIDs.isEmpty ? 0 : 80)
                }

                if !selectedIDs.isEmpty {
                    deleteBar
                }
            }
        }
        .navigationTitle(group.category.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                selectAllButton
            }
        }
        .alert("Delete failed", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Grid

    private var photoGrid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(visibleAssets.prefix(visibleCount), id: \.localIdentifier) { asset in
                SemanticCell(
                    asset: asset,
                    isSelected: selectedIDs.contains(asset.localIdentifier)
                ) {
                    if selectedIDs.contains(asset.localIdentifier) {
                        selectedIDs.remove(asset.localIdentifier)
                    } else {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        selectedIDs.insert(asset.localIdentifier)
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        Task { await deleteOne(asset: asset) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            if visibleCount < visibleAssets.count {
                Color.clear
                    .frame(height: 1)
                    .gridCellColumns(3)
                    .onAppear { visibleCount = min(visibleCount + 60, visibleAssets.count) }
            }
        }
    }

    // MARK: - Toolbar button

    @ViewBuilder
    private var selectAllButton: some View {
        if selectedIDs.isEmpty {
            Button(purchaseManager.isPurchased ? "Select All" : "Select 🔒") {
                guard purchaseManager.isPurchased else { showPaywall = true; return }
                visibleAssets.prefix(visibleCount).forEach { selectedIDs.insert($0.localIdentifier) }
            }
            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
        } else {
            Button("Deselect") {
                selectedIDs.removeAll()
            }
            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
        }
    }

    // MARK: - Floating delete bar

    private var deleteBar: some View {
        VStack {
            Spacer()
            HStack {
                Text("\(selectedIDs.count) selected")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    guard purchaseManager.isPurchased else { showPaywall = true; return }
                    Task { await deleteSelected() }
                } label: {
                    if isDeleting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Delete (\(selectedIDs.count))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .disabled(isDeleting)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Color.red.opacity(0.85), in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Color(white: 0.1, opacity: 0.97)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    // MARK: - Delete

    private func deleteSelected() async {
        isDeleting = true
        defer { isDeleting = false }

        let toDelete = visibleAssets.filter { selectedIDs.contains($0.localIdentifier) }
        guard !toDelete.isEmpty else { return }

        let bytes = toDelete.reduce(Int64(0)) { sum, asset in
            let size = PHAssetResource.assetResources(for: asset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return sum + size
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            }
            toDelete.forEach { deletedIDs.insert($0.localIdentifier) }
            selectedIDs.removeAll()
            NotificationCenter.default.post(name: .didFreeBytes, object: nil,
                                            userInfo: ["bytes": bytes, "count": toDelete.count])
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func deleteOne(asset: PHAsset) async {
        let bytes = PHAssetResource.assetResources(for: asset)
            .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            deletedIDs.insert(asset.localIdentifier)
            selectedIDs.remove(asset.localIdentifier)
            if bytes > 0 {
                NotificationCenter.default.post(name: .didFreeBytes, object: nil,
                                                userInfo: ["bytes": bytes, "count": 1])
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Individual delete (free) — long press context menu handled below

// MARK: - SemanticCell

private struct SemanticCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnail: UIImage?
    @State private var isDeleting = false

    private let size: CGFloat = (UIScreen.main.bounds.width - 4) / 3

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .overlay(ProgressView().tint(.white))
                    }
                }
                .frame(width: size, height: size)
                .clipped()

                if isSelected {
                    ZStack {
                        Circle()
                            .fill(Color(red: 1, green: 0.42, blue: 0.67))
                            .frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .task(id: asset.localIdentifier) { thumbnail = await loadThumbnail() }
    }

    private func loadThumbnail() async -> UIImage? {
        let key = "\(asset.localIdentifier)_semantic" as NSString
        if let cached = _semanticCellCache.object(forKey: key) { return cached }

        return await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.resizeMode = .fast

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 200, height: 200),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                if let image {
                    _semanticCellCache.setObject(
                        image, forKey: key,
                        cost: Int(image.size.width * image.size.height * 4)
                    )
                }
                continuation.resume(returning: image)
            }
        }
    }
}
