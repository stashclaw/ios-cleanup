import SwiftUI
import Photos

struct PhotoResultsView: View {
    let groups: [PhotoGroup]
    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var selectedGroups = Set<UUID>()
    @State private var isSelectMode = false
    @State private var showPaywall = false
    @State private var showSwipeMode = false
    @State private var deletionError: String?
    @State private var activeFilter: FilterPill = .all

    enum FilterPill: String, CaseIterable {
        case all = "All"
        case nearDuplicate = "Near Duplicates"
        case similar = "Similar"
        case burst = "Burst"
    }

    private var filteredGroups: [PhotoGroup] {
        switch activeFilter {
        case .all:          return groups
        case .nearDuplicate: return groups.filter { $0.reason == .nearDuplicate }
        case .similar:      return groups.filter { $0.reason == .visuallySimilar }
        case .burst:        return groups.filter { $0.reason == .burstShot }
        }
    }

    private var reclaimableBytes: Int64 {
        let assets = groups.flatMap { Array($0.assets.dropFirst()) }
        return assets.reduce(Int64(0)) { acc, a in acc + Int64(a.pixelWidth * a.pixelHeight / 100) }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                EmptyStateView(title: "No Duplicates Found", icon: "photo.on.rectangle.angled",
                               message: "Your photo library looks clean.")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        heroCard
                        filterPills
                        if let error = deletionError {
                            Text(error).font(.duckCaption).foregroundStyle(.red).padding(.horizontal)
                        }
                        groupList
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .background(Color.duckBlush.ignoresSafeArea())
            }
        }
        .navigationTitle("Similar Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Duck Mode") { showSwipeMode = true }
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckPink)

                if isSelectMode {
                    Button("Delete (\(selectedGroups.count))") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        Task { await bulkDelete() }
                    }
                    .disabled(selectedGroups.isEmpty)
                    .foregroundStyle(Color.duckRose)
                } else {
                    Button(purchaseManager.isPurchased ? "Select" : "Select 🔒") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        isSelectMode = true
                    }
                    .foregroundStyle(Color.duckPink)
                }
            }
            if isSelectMode {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isSelectMode = false
                        selectedGroups.removeAll()
                    }
                    .foregroundStyle(Color.duckRose)
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .fullScreenCover(isPresented: $showSwipeMode) {
            SwipeModeView(groups: groups).environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        DuckCard {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(groups.count)")
                        .font(Font.custom("FredokaOne-Regular", size: 32))
                        .foregroundStyle(Color.duckPink)
                    Text("groups to review")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }
                Spacer()
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.largeTitle)
                    .foregroundStyle(Color.duckSoftPink)
            }
            .padding(16)
        }
    }

    // MARK: - Filter pills

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FilterPill.allCases, id: \.self) { pill in
                    Button(pill.rawValue) {
                        activeFilter = pill
                    }
                    .font(.duckCaption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        activeFilter == pill ? Color.duckPink : Color.duckCream,
                        in: Capsule()
                    )
                    .foregroundStyle(activeFilter == pill ? Color.white : Color.duckRose)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Group list

    private var groupList: some View {
        VStack(spacing: 12) {
            ForEach(filteredGroups) { group in
                DuckCard {
                    NavigationLink(destination: PhotoGroupDetailView(group: group).environmentObject(purchaseManager)) {
                        GroupRow(
                            group: group,
                            isSelected: selectedGroups.contains(group.id),
                            isSelectMode: isSelectMode
                        )
                        .contentShape(Rectangle())
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        if isSelectMode {
                            if selectedGroups.contains(group.id) {
                                selectedGroups.remove(group.id)
                            } else {
                                selectedGroups.insert(group.id)
                            }
                        }
                    })
                    .padding(14)
                }
            }
        }
    }

    private func bulkDelete() async {
        let toDelete = groups
            .filter { selectedGroups.contains($0.id) }
            .flatMap { Array($0.assets.dropFirst()) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }
            selectedGroups.removeAll()
            isSelectMode = false
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

// MARK: - Group Row

private struct GroupRow: View {
    let group: PhotoGroup
    let isSelected: Bool
    let isSelectMode: Bool

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnailStack

            VStack(alignment: .leading, spacing: 4) {
                Text(reasonLabel)
                    .font(.duckBody)
                    .foregroundStyle(Color.duckBerry)
                Text("\(group.assets.count) photos")
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
            }

            Spacer()

            if isSelectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.duckPink : Color.duckSoftPink)
                    .font(.title3)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(Color.duckSoftPink)
            }
        }
        .task { thumbnail = await loadThumbnail(for: group.assets.first) }
    }

    private var thumbnailStack: some View {
        ZStack {
            ForEach(0..<min(3, group.assets.count), id: \.self) { i in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.duckSoftPink.opacity(0.4))
                    .frame(width: 48, height: 48)
                    .offset(x: CGFloat(i) * 4, y: CGFloat(-i) * 4)
            }
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: 60, height: 60)
    }

    private var reasonLabel: String {
        switch group.reason {
        case .nearDuplicate:  return "Near Duplicate"
        case .visuallySimilar: return "Similar"
        case .burstShot:      return "Burst Shot"
        }
    }

    private func loadThumbnail(for asset: PHAsset?) async -> UIImage? {
        guard let asset else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 100, height: 100),
                contentMode: .aspectFill, options: options
            ) { image, _ in continuation.resume(returning: image) }
        }
    }
}
