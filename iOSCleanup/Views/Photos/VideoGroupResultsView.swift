import SwiftUI
import Photos
import AVFoundation

// MARK: - Thumbnail cache (file-scope, avoids generic type restriction)

private let _videoThumbnailCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 200
    c.totalCostLimit = 30 * 1024 * 1024   // 30 MB
    return c
}()

// MARK: - Main View

struct VideoGroupResultsView: View {
    let groups: [VideoGroup]

    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var expandedGroupID: UUID?       // which group row is expanded
    @State private var deletedAssetIDs = Set<String>()
    @State private var deletedGroupIDs = Set<UUID>()
    @State private var isDeleting = false
    @State private var showPaywall = false
    @State private var deleteError: String?
    @State private var showDeleteConfirm = false

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let accent = Color(red: 1.0, green: 0.4, blue: 0.3)

    private var visibleGroups: [VideoGroup] {
        groups.filter { !deletedGroupIDs.contains($0.id) }
    }

    private var totalReclaimableBytes: Int64 {
        visibleGroups.reduce(Int64(0)) { sum, group in
            // All assets except the largest (assets[0]) are candidates for deletion.
            let dupeBytes = group.assets.dropFirst().reduce(Int64(0)) { s, asset in
                let size = PHAssetResource.assetResources(for: asset)
                    .first(where: { $0.type == .video })
                    .flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
                return s + size
            }
            return sum + dupeBytes
        }
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            if visibleGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        heroCard
                        groupList
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationTitle("Duplicate Videos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                bulkDeleteButton
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
        .alert("Delete All Duplicates?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { Task { await deleteAllDuplicates() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let savings = ByteCountFormatter.string(fromByteCount: totalReclaimableBytes, countStyle: .file)
            Text("This will delete all duplicate videos except the largest copy in each group. You'll free \(savings).")
        }
        if let err = deleteError {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 14)
                .fill(accent.opacity(0.15))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(accent)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("\(visibleGroups.count) duplicate group\(visibleGroups.count == 1 ? "" : "s")")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(ByteCountFormatter.string(fromByteCount: totalReclaimableBytes, countStyle: .file)) reclaimable")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(16)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(white: 1, opacity: 0.08)))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Group list

    private var groupList: some View {
        VStack(spacing: 8) {
            ForEach(visibleGroups) { group in
                VideoGroupRow(
                    group: group,
                    isExpanded: expandedGroupID == group.id,
                    deletedAssetIDs: deletedAssetIDs,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedGroupID = expandedGroupID == group.id ? nil : group.id
                        }
                    },
                    onDeleteAsset: { asset in
                        Task { await deleteSingleAsset(asset, in: group) }
                    },
                    onKeepLargestDeleteRest: {
                        Task { await keepLargestDeleteRest(in: group) }
                    }
                )
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Toolbar button

    private var bulkDeleteButton: some View {
        Button {
            guard purchaseManager.isPurchased else { showPaywall = true; return }
            showDeleteConfirm = true
        } label: {
            Text(purchaseManager.isPurchased ? "Delete All" : "Delete All 🔒")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
        }
        .disabled(isDeleting || visibleGroups.isEmpty)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color(red: 0.29, green: 0.85, blue: 0.6))
            Text("No Duplicate Videos Found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Your video library looks clean.")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .padding(40)
    }

    // MARK: - Delete actions

    private func deleteSingleAsset(_ asset: PHAsset, in group: VideoGroup) async {
        isDeleting = true
        defer { isDeleting = false }

        let bytes = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .video })
            .flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            deletedAssetIDs.insert(asset.localIdentifier)
            if bytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil, userInfo: ["bytes": bytes]
                )
            }
            // If all duplicates in the group are deleted (only keep candidate remains), hide group.
            let remaining = group.assets.filter { !deletedAssetIDs.contains($0.localIdentifier) }
            if remaining.count < 2 { deletedGroupIDs.insert(group.id) }
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func keepLargestDeleteRest(in group: VideoGroup) async {
        isDeleting = true
        defer { isDeleting = false }

        let toDelete = group.assets.dropFirst()  // assets[0] = largest/keep candidate
        guard !toDelete.isEmpty else { return }

        var bytes: Int64 = 0
        for asset in toDelete {
            bytes += PHAssetResource.assetResources(for: asset)
                .first(where: { $0.type == .video })
                .flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
        }

        do {
            let nsArray = Array(toDelete) as NSArray
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(nsArray)
            }
            toDelete.forEach { deletedAssetIDs.insert($0.localIdentifier) }
            deletedGroupIDs.insert(group.id)
            if bytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil, userInfo: ["bytes": bytes]
                )
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func deleteAllDuplicates() async {
        isDeleting = true
        defer { isDeleting = false }

        var allToDelete: [PHAsset] = []
        var totalBytes: Int64 = 0

        for group in visibleGroups {
            let dupes = Array(group.assets.dropFirst())
            allToDelete.append(contentsOf: dupes)
            for asset in dupes {
                totalBytes += PHAssetResource.assetResources(for: asset)
                    .first(where: { $0.type == .video })
                    .flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            }
        }

        guard !allToDelete.isEmpty else { return }

        do {
            let nsArray = allToDelete as NSArray
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(nsArray)
            }
            allToDelete.forEach { deletedAssetIDs.insert($0.localIdentifier) }
            visibleGroups.forEach { deletedGroupIDs.insert($0.id) }
            if totalBytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil, userInfo: ["bytes": totalBytes]
                )
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Group Row

private struct VideoGroupRow: View {
    let group: VideoGroup
    let isExpanded: Bool
    let deletedAssetIDs: Set<String>
    let onToggle: () -> Void
    let onDeleteAsset: (PHAsset) -> Void
    let onKeepLargestDeleteRest: () -> Void

    private let accent = Color(red: 1.0, green: 0.4, blue: 0.3)

    private var visibleAssets: [PHAsset] {
        group.assets.filter { !deletedAssetIDs.contains($0.localIdentifier) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Collapsed row header
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    VideoThumbnailCell(asset: group.assets[0], size: 80)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(visibleAssets.count) videos · \(ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file)) total")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        reasonBadge
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                Divider().overlay(Color(white: 1, opacity: 0.07))

                VStack(spacing: 0) {
                    ForEach(Array(visibleAssets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                        VideoAssetRow(
                            asset: asset,
                            isKeepCandidate: idx == 0,
                            onDelete: { onDeleteAsset(asset) }
                        )
                        if idx < visibleAssets.count - 1 {
                            Divider().overlay(Color(white: 1, opacity: 0.05)).padding(.leading, 80 + 14 + 12)
                        }
                    }

                    if visibleAssets.count >= 2 {
                        Divider().overlay(Color(white: 1, opacity: 0.07))
                        Button(action: onKeepLargestDeleteRest) {
                            HStack {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                Text("Keep Largest, Delete Rest")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(white: 1, opacity: 0.07)))
    }

    private var reasonBadge: some View {
        Text(group.reason == .exactDuplicate ? "Exact Duplicate" : "Near Duplicate")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(accent.opacity(0.15), in: Capsule())
    }
}

// MARK: - Individual Asset Row (expanded)

private struct VideoAssetRow: View {
    let asset: PHAsset
    let isKeepCandidate: Bool
    let onDelete: () -> Void

    private let accent = Color(red: 1.0, green: 0.4, blue: 0.3)
    private let keepColor = Color(red: 0.29, green: 0.85, blue: 0.6)

    private var fileSize: String {
        let bytes = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .video })
            .flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var durationText: String {
        let d = asset.duration
        let m = Int(d) / 60, s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnailCell(asset: asset, size: 80)

            VStack(alignment: .leading, spacing: 4) {
                Text(fileSize)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(durationText)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                if let date = asset.creationDate {
                    Text(date, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }

            Spacer()

            if isKeepCandidate {
                Text("Keep")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(keepColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(keepColor.opacity(0.15), in: Capsule())
            } else {
                Button(action: onDelete) {
                    Text("Delete")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(accent.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Self-loading video thumbnail cell

private struct VideoThumbnailCell: View {
    let asset: PHAsset
    let size: CGFloat

    @State private var thumbnail: UIImage?

    private var durationText: String {
        let d = asset.duration
        let m = Int(d) / 60, s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color(white: 1, opacity: 0.08))
                        .overlay(ProgressView().tint(.white))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Duration badge
            Text(durationText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
        }
        .frame(width: size, height: size)
        .task(id: asset.localIdentifier) { thumbnail = await loadThumbnail() }
    }

    private func loadThumbnail() async -> UIImage? {
        let key = "\(asset.localIdentifier)_\(Int(size))" as NSString
        if let cached = _videoThumbnailCache.object(forKey: key) { return cached }

        return await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.resizeMode = .fast

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: size * 2, height: size * 2),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                if let image {
                    _videoThumbnailCache.setObject(
                        image, forKey: key,
                        cost: Int(image.size.width * image.size.height * 4)
                    )
                }
                continuation.resume(returning: image)
            }
        }
    }
}
