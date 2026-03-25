import SwiftUI
import Photos

// MARK: - NSCache (file-scope, shared across all cells)

private let _eventRollCellCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 400
    c.totalCostLimit = 50 * 1024 * 1024   // 50 MB
    return c
}()

// MARK: - EventRollResultsView

struct EventRollResultsView: View {

    let rolls: [EventRoll]

    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var homeViewModel: HomeViewModel

    @State private var deletedRollIDs  = Set<UUID>()
    @State private var deletedAssetIDs = Set<String>()
    @State private var isDeleting      = false
    @State private var deleteError:    String?
    @State private var showPaywall     = false
    @State private var selectedRoll:   EventRoll? = nil

    private let bg     = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let accent = Color(red: 0.4,  green: 0.6,  blue: 1.0)

    private var visibleRolls: [EventRoll] {
        rolls.filter { !deletedRollIDs.contains($0.id) }
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            Group {
                if visibleRolls.isEmpty {
                    emptyState
                } else {
                    rollList
                }
            }
        }
        .navigationTitle("Event Rolls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
        // Detail navigation — full 3-col grid of the tapped roll
        .navigationDestination(isPresented: Binding(
            get: { selectedRoll != nil },
            set: { if !$0 { selectedRoll = nil } }
        )) {
            if let roll = selectedRoll {
                RollDetailView(roll: roll, accent: accent,
                               deletedAssetIDs: $deletedAssetIDs)
                    .environmentObject(purchaseManager)
                    .environmentObject(homeViewModel)
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(accent.opacity(0.6))
            Text("No Event Rolls")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Photos from the same time and place\nwill appear here.")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rollList: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroCard
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                if let error = deleteError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }

                LazyVStack(spacing: 1) {
                    ForEach(visibleRolls) { roll in
                        RollRow(roll: roll, accent: accent) {
                            selectedRoll = roll
                        }
                    }
                }
            }
            .padding(.bottom, 32)
        }
    }

    private var heroCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14)
                .fill(accent.opacity(0.15))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "photo.stack")
                        .font(.system(size: 22))
                        .foregroundStyle(accent)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("\(visibleRolls.count) Event Rolls")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                let totalPhotos = visibleRolls.reduce(0) { $0 + $1.photoCount }
                Text("\(totalPhotos) photos · Tap a roll to review")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(14)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(white: 1, opacity: 0.07)))
    }
}

// MARK: - Roll Row

private struct RollRow: View {
    let roll:   EventRoll
    let accent: Color
    let onTap:  () -> Void

    private static let dateRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Thumbnail strip — 3 photos
                HStack(spacing: 3) {
                    ForEach(0..<min(3, roll.assets.count), id: \.self) { i in
                        ThumbnailCell(asset: roll.assets[i])
                    }
                }
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Text info
                VStack(alignment: .leading, spacing: 4) {
                    Text(roll.locationName ?? "Unknown Location")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(dateRangeText)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(2)

                    Text("\(roll.photoCount) photos")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.15), in: Capsule())
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.2))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider()
            .overlay(Color.white.opacity(0.06))
            .padding(.leading, 20 + 3 * 56 + 12)   // align with text column
    }

    private var dateRangeText: String {
        let start = roll.startDate
        let end   = roll.endDate
        let cal   = Calendar.current

        let startStr = Self.dateRangeFormatter.string(from: start)
        let endStr   = Self.dateRangeFormatter.string(from: end)

        if cal.isDate(start, inSameDayAs: end) {
            // Same day: "Mar 22 · 3:14 PM – 5:47 PM"
            return "\(startStr) · \(Self.timeFormatter.string(from: start)) – \(Self.timeFormatter.string(from: end))"
        } else {
            // Multi-day: "Mar 22 – Mar 23"
            return "\(startStr) – \(endStr)"
        }
    }
}

// MARK: - Self-loading thumbnail cell

private struct ThumbnailCell: View {
    let asset: PHAsset

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 72)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 56, height: 72)
                    .overlay(ProgressView().tint(Color.white.opacity(0.3)).scaleEffect(0.6))
            }
        }
        .task(id: asset.localIdentifier) { image = await loadThumbnail() }
    }

    private func loadThumbnail() async -> UIImage? {
        let key = "\(asset.localIdentifier)_eventroll_56" as NSString
        if let cached = _eventRollCellCache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.resizeMode = .fast
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 112, height: 144),
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                guard !resumed else { return }
                resumed = true
                if let img {
                    _eventRollCellCache.setObject(
                        img, forKey: key,
                        cost: Int(img.size.width * img.size.height * 4)
                    )
                }
                continuation.resume(returning: img)
            }
        }
    }
}

// MARK: - Roll Detail View (full 3-column grid)

private struct RollDetailView: View {
    let roll:   EventRoll
    let accent: Color
    @Binding var deletedAssetIDs: Set<String>

    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var homeViewModel:   HomeViewModel

    @State private var selectedIDs = Set<String>()
    @State private var isDeleting  = false
    @State private var deleteError: String?
    @State private var showPaywall = false
    @State private var visibleCount = 60

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)

    private var visibleAssets: [PHAsset] {
        roll.assets.filter { !deletedAssetIDs.contains($0.localIdentifier) }
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    if let error = deleteError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding()
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                        spacing: 2
                    ) {
                        ForEach(visibleAssets.prefix(visibleCount), id: \.localIdentifier) { asset in
                            DetailCell(
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
                        }
                        if visibleCount < visibleAssets.count {
                            Color.clear
                                .frame(height: 1)
                                .gridCellColumns(3)
                                .onAppear { visibleCount = min(visibleCount + 60, visibleAssets.count) }
                        }
                    }
                }
                .padding(.bottom, 80)
            }

            // Floating bulk-delete bar
            if !selectedIDs.isEmpty {
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
                            Label(isDeleting ? "Deleting…" : "Delete", systemImage: "trash.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.85), in: Capsule())
                        }
                        .disabled(isDeleting)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.1, opacity: 0.95))
                    .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.white.opacity(0.1)), alignment: .top)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(roll.locationName ?? "Event Roll")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(purchaseManager.isPurchased ? "Select All" : "Select 🔒") {
                    guard purchaseManager.isPurchased else { showPaywall = true; return }
                    visibleAssets.prefix(visibleCount).forEach {
                        selectedIDs.insert($0.localIdentifier)
                    }
                }
                .foregroundStyle(accent)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    private func deleteSelected() async {
        isDeleting  = true
        deleteError = nil
        let ids     = selectedIDs
        let toDelete = visibleAssets.filter { ids.contains($0.localIdentifier) }

        // Compute bytes before deletion
        let bytes = toDelete.reduce(Int64(0)) { sum, asset in
            let size = PHAssetResource.assetResources(for: asset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return sum + size
        }

        do {
            let nsArray = toDelete as NSArray
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(nsArray)
            }
            for id in ids { deletedAssetIDs.insert(id) }
            selectedIDs.removeAll()
            if bytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil, userInfo: ["bytes": bytes])
            }
        } catch {
            deleteError = error.localizedDescription
        }
        isDeleting = false
    }
}

// MARK: - Detail cell (self-loading)

private let _rollDetailCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 300
    c.totalCostLimit = 40 * 1024 * 1024
    return c
}()

private struct DetailCell: View {
    let asset:      PHAsset
    let isSelected: Bool
    let onTap:      () -> Void

    @State private var thumbnail: UIImage?

    private let size = CGSize(width: 200, height: 200)

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                    }
                }
                .frame(width: size.width, height: size.width)
                .clipped()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.blue))
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) { thumbnail = await loadThumbnail() }
    }

    private func loadThumbnail() async -> UIImage? {
        let key = "\(asset.localIdentifier)_rolldetail_200" as NSString
        if let cached = _rollDetailCache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            opts.resizeMode = .fast
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                guard !resumed else { return }
                resumed = true
                if let img {
                    _rollDetailCache.setObject(
                        img, forKey: key,
                        cost: Int(img.size.width * img.size.height * 4)
                    )
                }
                continuation.resume(returning: img)
            }
        }
    }
}
