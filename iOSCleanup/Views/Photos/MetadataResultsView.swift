import SwiftUI
import Photos

// MARK: - MetadataResultsView

/// Generic 3-column grid for flat [PHAsset] metadata categories
/// (Panoramas, Portrait Mode, Live Photos).
/// No scan engine required — assets are fetched via PHAsset subtype predicates.
struct MetadataResultsView: View {
    let title:    String
    let subtitle: String
    let icon:     String
    let accent:   Color
    let assets:   [PHAsset]

    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var homeViewModel: HomeViewModel

    @State private var selectedIDs  = Set<String>()
    @State private var deletedIDs   = Set<String>()
    @State private var isDeleting   = false
    @State private var deleteError: String?
    @State private var showPaywall  = false
    @State private var visibleCount = 60

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)

    private var visibleAssets: [PHAsset] {
        assets.filter { !deletedIDs.contains($0.localIdentifier) }
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            Group {
                if visibleAssets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 48))
                            .foregroundStyle(accent.opacity(0.6))
                        Text("No \(title)")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("No \(subtitle.lowercased()) found.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            heroCard
                            if let error = deleteError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal)
                            }
                            photoGrid
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedIDs.isEmpty {
                    Button(purchaseManager.isPurchased ? "Select All" : "Select 🔒") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        visibleAssets.prefix(visibleCount).forEach {
                            selectedIDs.insert($0.localIdentifier)
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(accent)
                } else {
                    Button("Delete (\(selectedIDs.count))") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        Task { await deleteSelected() }
                    }
                    .disabled(isDeleting)
                    .foregroundStyle(accent)
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(visibleAssets.count)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                Text(subtitle.lowercased())
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(accent.opacity(0.7))
        }
        .padding(16)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.25)))
    }

    // MARK: - 3-column photo grid

    private var photoGrid: some View {
        let gap: CGFloat = 10
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: 3)
        let cardPt  = (UIScreen.main.bounds.width - 52) / 3   // 16+16 padding + 10+10 gaps

        return LazyVGrid(columns: columns, spacing: gap) {
            ForEach(visibleAssets.prefix(visibleCount), id: \.localIdentifier) { asset in
                MetadataCell(
                    asset: asset,
                    isSelected: selectedIDs.contains(asset.localIdentifier),
                    accent: accent,
                    onTap: {
                        if selectedIDs.contains(asset.localIdentifier) {
                            selectedIDs.remove(asset.localIdentifier)
                        } else {
                            selectedIDs.insert(asset.localIdentifier)
                        }
                    },
                    onDelete: { Task { await deleteSingle(asset) } }
                )
                .frame(height: cardPt)
                .clipped()
            }
            if visibleCount < visibleAssets.count {
                Color.clear.frame(height: 1).gridCellColumns(3)
                    .onAppear { visibleCount = min(visibleCount + 60, visibleAssets.count) }
            }
        }
    }

    // MARK: - Delete (bulk)

    private func deleteSelected() async {
        isDeleting = true
        defer { isDeleting = false }
        let toDelete = visibleAssets.filter { selectedIDs.contains($0.localIdentifier) }
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
            if bytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil,
                    userInfo: ["bytes": bytes]
                )
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }

    // MARK: - Delete (individual, free)

    private func deleteSingle(_ asset: PHAsset) async {
        let bytes = PHAssetResource.assetResources(for: asset)
            .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            deletedIDs.insert(asset.localIdentifier)
            selectedIDs.remove(asset.localIdentifier)
            if bytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil,
                    userInfo: ["bytes": bytes]
                )
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Cell

private let _metadataCellCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 300
    c.totalCostLimit = 40 * 1024 * 1024
    return c
}()

@MainActor
private let _metadataCellPx: CGFloat = {
    let scale = UIScreen.main.scale
    return ((UIScreen.main.bounds.width - 32 - 20) / 3) * scale
}()

private struct MetadataCell: View {
    let asset:    PHAsset
    let isSelected: Bool
    let accent:   Color
    let onTap:    () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbnail {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.12)
                            .overlay(ProgressView().scaleEffect(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(isSelected ? accent.opacity(0.35) : Color.clear)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .background(Circle().fill(accent).padding(2))
                        .padding(5)
                }

                // Individual delete button — bottom trailing, free (no paywall)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: onDelete) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.6), in: Circle())
                        }
                        .padding(6)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? accent : accent.opacity(0.2),
                          lineWidth: isSelected ? 2 : 1))
        .onAppear  { load() }
        .onDisappear { cancel() }
    }

    private func load() {
        let key = "\(asset.localIdentifier)_meta" as NSString
        if let cached = _metadataCellCache.object(forKey: key) { thumbnail = cached; return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = false
        opts.resizeMode = .fast
        let px = _metadataCellPx
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: px, height: px),
            contentMode: .aspectFill,
            options: opts
        ) { image, info in
            guard let image else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !degraded {
                _metadataCellCache.setObject(image, forKey: key,
                                             cost: Int(image.size.width * image.size.height * 4))
            }
            Task { @MainActor in thumbnail = image }
        }
    }

    private func cancel() {
        if let id = requestID {
            PHImageManager.default().cancelImageRequest(id)
            requestID = nil
        }
    }
}
