import SwiftUI
import Photos
import UIKit

struct PhotoDuckShellView: View {
    @ObservedObject var dashboardModel: HomeViewModel
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @EnvironmentObject private var notificationRouter: CleanupNotificationRouter
    @State private var selectedTab: Tab = .similar

    enum Tab: Hashable {
        case home, similar, contacts, files
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                viewModel: dashboardModel,
                isHomeTabSelected: Binding(
                    get: { selectedTab == .home },
                    set: { if $0 { selectedTab = .home } }
                )
            )
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            NavigationStack {
                SimilarPhotosDashboardView(viewModel: dashboardModel)
                    .environmentObject(purchaseManager)
                    .environmentObject(deletionManager)
            }
            .tabItem { Label("Similar", systemImage: "photo.stack.fill") }
            .tag(Tab.similar)

            NavigationStack {
                ContactResultsView(matches: dashboardModel.contactMatches)
                    .environmentObject(purchaseManager)
            }
            .tabItem { Label("Contacts", systemImage: "person.2.fill") }
            .tag(Tab.contacts)

            NavigationStack {
                FileResultsView(files: dashboardModel.largeFiles)
                    .environmentObject(purchaseManager)
            }
            .tabItem { Label("Files", systemImage: "doc.fill") }
            .tag(Tab.files)
        }
        .tint(Color.duckPink)
        .onChange(of: notificationRouter.pendingTarget) { target in
            guard let target else { return }
            switch target {
            case .reviewResults:
                selectedTab = .similar
            }
            notificationRouter.pendingTarget = nil
        }
    }
}

struct SimilarPhotosDashboardView: View {
    @ObservedObject var viewModel: HomeViewModel
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @State private var showSwipeMode = false
    @State private var showReviewResults = false

    private var similarGroups: [PhotoGroup] { viewModel.photoGroups }
    private var featuredGroups: [PhotoGroup] { Array(similarGroups.prefix(4)) }
    private var totalPhotoCount: Int {
        viewModel.libraryTotalCount > 0 ? viewModel.libraryTotalCount : similarGroups.reduce(0) { $0 + $1.photoCount }
    }
    private var totalReclaimableBytes: Int64 {
        similarGroups.reduce(into: Int64(0)) { acc, group in
            acc += group.reclaimableBytes
        }
    }
    private var cleanedBytes: Int64 { max(deletionManager.totalBytesFreed, 0) }
    private var cleanedItems: Int { max(deletionManager.totalItemsFreed, 0) }
    private var remainingGroups: Int { max(similarGroups.count - cleanedItems, 0) }
    private var scanProgress: Double { viewModel.scanState == .scanning ? viewModel.progressFraction : (similarGroups.isEmpty ? 0 : 1) }
    private var reclaimablePercent: Int {
        guard viewModel.storageTotalBytesValue > 0 else { return 0 }
        let fraction = Double(totalReclaimableBytes) / Double(viewModel.storageTotalBytesValue)
        return Int((fraction * 100).rounded())
    }

    private var dashboardSubtitle: String {
        if viewModel.scanState == .scanning {
            return "\(viewModel.scanProgressLabel) · \(viewModel.scanRateLabel)"
        }
        if similarGroups.isEmpty {
            return "Run a scan from Home to build a faster cleanup queue."
        }
        return "Can free up \(reclaimablePercent)% of storage"
    }

    private var sessionSummaryText: String {
        if cleanedItems > 0 {
            return "\(cleanedItems) items / \(ByteCountFormatter.string(fromByteCount: cleanedBytes, countStyle: .file)) moved to Trash"
        }
        return "\(similarGroups.count) groups ready · \(ByteCountFormatter.string(fromByteCount: totalReclaimableBytes, countStyle: .file)) reclaimable"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.72, blue: 0.56),
                    Color(red: 0.11, green: 0.34, blue: 0.22),
                    Color.black.opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                    diagnosticsStrip

                    if similarGroups.isEmpty {
                        emptyState
                    } else {
                        collageSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Smart Cleanup") {
                        if similarGroups.isEmpty {
                            Task { await viewModel.scanPhotos() }
                        } else {
                            showSwipeMode = true
                        }
                    }
                    Button("Review Results") { showReviewResults = true }
                    Button("Scan Again") { Task { await viewModel.scanPhotos() } }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(Color.white)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            actionDock
        }
        .sheet(isPresented: $showReviewResults) {
            NavigationStack {
                PhotoResultsView(groups: viewModel.photoGroups)
                    .environmentObject(purchaseManager)
                    .environmentObject(deletionManager)
            }
        }
        .fullScreenCover(isPresented: $showSwipeMode) {
            SwipeModeView(groups: viewModel.photoGroups)
                .environmentObject(purchaseManager)
                .environmentObject(deletionManager)
        }
    }

    private var heroCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.26, green: 0.78, blue: 0.62),
                            Color(red: 0.14, green: 0.48, blue: 0.32),
                            Color(red: 0.06, green: 0.22, blue: 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RadialGradient(
                        colors: [Color.white.opacity(0.16), Color.clear],
                        center: .topTrailing,
                        startRadius: 10,
                        endRadius: 220
                    )
                    .blendMode(.screen)
                )
                .shadow(color: .black.opacity(0.24), radius: 14, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Similars")
                            .font(.duckDisplay(52))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 2)

                        Text("\(totalPhotoCount.formatted()) photo(s) • \(ByteCountFormatter.string(fromByteCount: totalReclaimableBytes, countStyle: .file)) reclaimable")
                            .font(.duckHeading)
                            .foregroundStyle(Color.white.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(dashboardSubtitle)
                            .font(.duckCaption)
                            .foregroundStyle(Color.white.opacity(0.86))
                    }

                    Spacer(minLength: 10)

                    VStack(alignment: .trailing, spacing: 10) {
                        Menu {
                            Button("Smart Cleanup") { showSwipeMode = true }
                            Button("Review Results") { showReviewResults = true }
                            Button("Scan Again") { Task { await viewModel.scanPhotos() } }
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.14), in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        }

                        SimilarDashboardRing(progress: scanProgress, accent: .white, label: viewModel.scanState == .scanning ? "Scanning" : "Ready")
                            .frame(width: 112, height: 112)
                    }
                }

                HStack(spacing: 12) {
                    PhotoDuckStatTile(
                        title: "Total cleaned",
                        value: "\(cleanedItems) files\n\(ByteCountFormatter.string(fromByteCount: cleanedBytes, countStyle: .file))",
                        accent: .duckPink,
                        icon: "doc.fill"
                    )

                    PhotoDuckStatTile(
                        title: "Review progress",
                        value: "\(Int((scanProgress * 100).rounded()))%",
                        accent: .duckYellow,
                        icon: "circle.dashed"
                    )

                    PhotoDuckStatTile(
                        title: "Remaining",
                        value: "\(remainingGroups)\ngroups",
                        accent: .duckSoftPink,
                        icon: "sparkles"
                    )
                }

                HStack(spacing: 8) {
                    StatusBadge(title: "\(similarGroups.count) groups ready", accent: .duckPink)
                    StatusBadge(title: "\(viewModel.reviewablePhotosCount) reviewable", accent: .duckOrange)
                }
            }
            .padding(18)
        }
    }

    private var diagnosticsStrip: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Scan diagnostics")
                        .font(.duckHeading)
                        .foregroundStyle(Color.duckCream)
                    Spacer()
                    StatusBadge(title: viewModel.scanState == .scanning ? "Scanning" : "Ready", accent: .duckPink)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatPill(
                        title: "Photos",
                        value: viewModel.scanProgressLabel,
                        accent: .duckPink,
                        icon: "photo.on.rectangle.angled"
                    )
                    StatPill(
                        title: "Rate",
                        value: viewModel.scanRateLabel,
                        accent: .duckOrange,
                        icon: "speedometer"
                    )
                    StatPill(
                        title: "Matches",
                        value: "\(viewModel.reviewablePhotosCount.formatted())",
                        accent: .duckRose,
                        icon: "sparkles"
                    )
                }
            }
            .padding(16)
        }
    }

    private var collageSection: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Best shots ready")
                            .font(.duckHeading)
                            .foregroundStyle(Color.duckBerry)
                        Text("\(similarGroups.count) groups grouped for fast cleanup")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                    }
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(featuredGroups) { group in
                        SimilarGroupPreviewCard(group: group)
                    }
                }
            }
            .padding(16)
        }
    }

    private var actionDock: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    PhotoDuckAssetImage(
                        assetNames: ["photoduck_mascot", "photoduck_logo"],
                        fallback: { PhotoDuckMascotFallback(size: 44) }
                    )
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(sessionSummaryText)
                            .font(.duckHeading)
                            .foregroundStyle(Color.duckBerry)
                        Text(viewModel.heroSecondaryText)
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                    }

                    Spacer(minLength: 0)
                }

                DuckPrimaryButton(title: "Smart Cleanup") {
                    if similarGroups.isEmpty {
                        Task { await viewModel.scanPhotos() }
                    } else {
                        showSwipeMode = true
                    }
                }

                HStack(spacing: 12) {
                    DuckOutlineButton(title: "Review results", color: .duckPink) {
                        showReviewResults = true
                    }
                    DuckOutlineButton(title: "Scan again", color: .duckRose) {
                        Task { await viewModel.scanPhotos() }
                    }
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        DuckCard {
            VStack(spacing: 14) {
                PhotoDuckAssetImage(
                    assetNames: ["photoduck_mascot", "photoduck_logo"],
                    fallback: { PhotoDuckMascotFallback(size: 72) }
                )
                .frame(width: 96, height: 96)

                VStack(spacing: 6) {
                    Text("No similar photos yet")
                        .font(.duckTitle)
                        .foregroundStyle(Color.duckBerry)
                    Text("Run a photo scan from Home or start Smart Cleanup to build the queue.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                        .multilineTextAlignment(.center)
                }

                DuckPrimaryButton(title: "Scan for Similar Photos") {
                    Task { await viewModel.scanPhotos() }
                }
            }
            .padding(18)
        }
    }
}

private struct SimilarDashboardRing: View {
    let progress: Double
    let accent: Color
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(accent, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.duckTitle)
                    .foregroundStyle(.white)
                Text(label)
                    .font(.duckLabel)
                    .foregroundStyle(Color.white.opacity(0.86))
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
    }
}

private struct SimilarGroupPreviewCard: View {
    let group: PhotoGroup
    @State private var images: [String: UIImage] = [:]

    private var leadAssets: [PHAsset] {
        Array(group.assets.prefix(2))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.black.opacity(0.26)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 178)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(reasonLabel)
                        .font(.duckLabel.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.26), in: Capsule())
                    Spacer(minLength: 0)
                }

                GeometryReader { proxy in
                    let tileWidth = max(0, (proxy.size.width - 8) / 2)
                    HStack(spacing: 8) {
                        ForEach(Array(leadAssets.enumerated()), id: \.offset) { index, asset in
                            thumbnailTile(for: asset, isLeading: index == 0)
                                .frame(width: tileWidth, height: tileWidth)
                        }
                    }
                }
                .frame(height: 92)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(group.assets.count) photos")
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.white)
                    Text("Best shot selected")
                        .font(.duckLabel)
                        .foregroundStyle(Color.white.opacity(0.88))
                }
            }
            .padding(12)
        }
        .task(id: group.id) { await loadThumbnails() }
    }

    private var reasonLabel: String {
        switch group.reason {
        case .nearDuplicate: return "Near Duplicate"
        case .visuallySimilar: return "Similar"
        case .burstShot: return "Burst"
        }
    }

    private func loadThumbnails() async {
        for asset in leadAssets {
            let size = CGSize(width: 360, height: 360)
            let image = await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: size,
                    contentMode: .aspectFill,
                    options: options
                ) { result, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                    guard !isDegraded else { return }
                    continuation.resume(returning: result)
                }
            }
            if let image {
                images[asset.localIdentifier] = image
            }
        }
    }

    @ViewBuilder
    private func thumbnailTile(for asset: PHAsset, isLeading: Bool) -> some View {
        ZStack {
            if let image = images[asset.localIdentifier] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [Color.duckSoftPink.opacity(0.55), Color.duckPink.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay {
                    ProgressView().tint(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isLeading ? Color.white.opacity(0.35) : Color.white.opacity(0.20), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct PhotoDuckStatTile: View {
    let title: String
    let value: String
    let accent: Color
    let icon: String

    var body: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(accent)
                    Spacer()
                }
                Text(title)
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
                Text(value)
                    .font(.duckTitle)
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(16)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PhotoDuckAssetImage<Fallback: View>: View {
    let assetNames: [String]
    let fallback: Fallback

    init(assetNames: [String], @ViewBuilder fallback: () -> Fallback) {
        self.assetNames = assetNames
        self.fallback = fallback()
    }

    var body: some View {
        if let assetName = assetNames.first(where: { UIImage(named: $0) != nil }) {
            Image(assetName)
                .resizable()
                .scaledToFit()
        } else {
            fallback
        }
    }
}

struct PhotoDuckMascotFallback: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.duckYellow, Color.duckPink.opacity(0.85)],
                        center: .topLeading,
                        startRadius: 4,
                        endRadius: size * 0.8
                    )
                )
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: size * 0.14, height: size * 0.14)
                .offset(x: -size * 0.16, y: -size * 0.10)
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: size * 0.14, height: size * 0.14)
                .offset(x: size * 0.08, y: -size * 0.10)
            Capsule(style: .continuous)
                .fill(Color.duckOrange)
                .frame(width: size * 0.34, height: size * 0.20)
                .offset(x: size * 0.12, y: size * 0.10)
        }
        .frame(width: size, height: size)
    }
}
