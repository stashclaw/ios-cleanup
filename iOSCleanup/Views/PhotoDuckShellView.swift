import SwiftUI
import Photos
import UIKit

struct PhotoDuckShellView: View {
    @ObservedObject var dashboardModel: HomeViewModel
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @EnvironmentObject private var notificationRouter: CleanupNotificationRouter
    @State private var selectedTab: Tab = .home

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
                ContactResultsView(
                    matches: dashboardModel.contactMatches,
                    scanState: dashboardModel.contactScanState,
                    onRefresh: { await dashboardModel.scanContacts(force: true) }
                )
                    .environmentObject(purchaseManager)
            }
            .tabItem { Label("Contacts", systemImage: "person.2.fill") }
            .tag(Tab.contacts)

            NavigationStack {
                FileResultsView(
                    files: dashboardModel.largeFiles,
                    scanState: dashboardModel.fileScanState,
                    onRefresh: { await dashboardModel.scanFiles(force: true) }
                )
                    .environmentObject(purchaseManager)
            }
            .tabItem { Label("Files", systemImage: "doc.fill") }
            .tag(Tab.files)
        }
        .tint(Color.accentPrimary)
        .toolbarBackground(Color.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onChange(of: selectedTab) { tab in
            switch tab {
            case .contacts:
                Task { await dashboardModel.scanContacts() }
            case .files:
                Task { await dashboardModel.scanFiles() }
            case .home, .similar:
                break
            }
        }
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
    @State private var isExportingMLData = false
    @State private var mlExportMessage: String?

    private var similarGroups: [PhotoGroup] { viewModel.photoGroups }
    private var featuredGroups: [PhotoGroup] { Array(similarGroups.prefix(4)) }
    private var totalPhotoCount: Int {
        Set(similarGroups.flatMap(\.assets).map(\.localIdentifier)).count
    }
    private var totalReclaimableBytes: Int64 {
        similarGroups.reduce(into: Int64(0)) { acc, group in
            acc += group.reclaimableBytes
        }
    }
    private var remainingGroups: Int { similarGroups.count }
    private var scanProgress: Double {
        switch viewModel.scanState {
        case .scanning, .paused:
            return viewModel.progressFraction
        case .completed:
            return 1
        default:
            return similarGroups.isEmpty ? 0 : viewModel.progressFraction
        }
    }
    private var scanStatusLabel: String {
        switch viewModel.scanState {
        case .scanning: return "Scanning"
        case .paused: return "Paused"
        case .completed:
            return viewModel.unanalyzedPhotoCount > 0 ? "Incomplete" : "Ready"
        case .failed: return "Needs attention"
        case .permissionRequired: return "Access needed"
        case .idle: return "Not scanned"
        }
    }

    private var scanPercentLabel: String {
        if viewModel.scanState == .completed, viewModel.unanalyzedPhotoCount > 0 {
            return "\(viewModel.unanalyzedPhotoCount.formatted()) not analyzed"
        }
        return "\(Int((scanProgress * 100).rounded()))% scanned"
    }
    private var heroMetricText: String {
        if viewModel.scanState == .scanning || viewModel.scanState == .paused {
            return "\(viewModel.scanProgressLabel) • \(similarGroups.count) groups found"
        }
        return "\(totalPhotoCount.formatted()) photos • \(ByteCountFormatter.string(fromByteCount: totalReclaimableBytes, countStyle: .file)) reclaimable"
    }
    private var reclaimablePercent: Int {
        guard viewModel.storageTotalBytesValue > 0 else { return 0 }
        let fraction = Double(totalReclaimableBytes) / Double(viewModel.storageTotalBytesValue)
        return Int((fraction * 100).rounded())
    }

    private var dashboardSubtitle: String {
        if viewModel.scanState == .scanning {
            return "\(viewModel.scanProgressLabel) · \(viewModel.scanRateLabel)"
        }
        if viewModel.scanState == .paused {
            return "\(viewModel.processedPhotoCount.formatted()) photos scanned so far · continue when ready"
        }
        if similarGroups.isEmpty {
            return "Run a scan from Home to build a faster cleanup queue."
        }
        return "Can free up \(reclaimablePercent)% of storage"
    }

    private var showsScanDetails: Bool {
        viewModel.scanState == .scanning || viewModel.scanState == .paused
    }

    var body: some View {
        ZStack {
            Color.backgroundBlush.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    heroCard

                    if showsScanDetails {
                        diagnosticsStrip
                    }

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
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if viewModel.scanState == .paused {
                        Button("Continue Scanning") { viewModel.resumeDeepClean() }
                    } else if viewModel.scanState == .scanning, viewModel.cleanupMode == .deepClean {
                        Button("Pause Deep Clean") { viewModel.pauseDeepClean() }
                    }
                    Button("Smart Cleanup") {
                        if similarGroups.isEmpty {
                            Task { await viewModel.scanPhotos() }
                        } else {
                            showSwipeMode = true
                        }
                    }
                    Button("Review Results") { showReviewResults = true }
                    Button("Scan Again") { Task { await viewModel.scanPhotos() } }
#if DEBUG
                    Divider()
                    Button(isExportingMLData ? "Exporting ML Data..." : "Export ML Training Data") {
                        Task { await exportMLTrainingData() }
                    }
                    .disabled(isExportingMLData)
#endif
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(Color.textSecondary)
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
            .deletionUndoToast()
        }
        .fullScreenCover(isPresented: $showSwipeMode) {
            SwipeModeView(groups: viewModel.photoGroups)
                .environmentObject(purchaseManager)
                .environmentObject(deletionManager)
                .deletionUndoToast()
        }
        .alert(
            "ML Training Export",
            isPresented: Binding(
                get: { mlExportMessage != nil },
                set: { if !$0 { mlExportMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                mlExportMessage = nil
            }
        } message: {
            Text(mlExportMessage ?? "")
        }
    }

    // Direction 3b: the hero is the one saturated moment on the dashboard —
    // brand gradient card with white content and white-on-white-16% stat tiles.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Similar photos")
                        .font(.duckTitle)
                        .foregroundStyle(.white)

                    Text(heroMetricText)
                        .font(.duckHeading)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(dashboardSubtitle)
                        .font(.duckCaption)
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
                PhotoDuckMascotArt(size: 72)
            }

            HStack(spacing: 10) {
                HeroStatTile(
                    title: "Groups",
                    value: remainingGroups.formatted(),
                    icon: "photo.stack.fill"
                )
                HeroStatTile(
                    title: "Reviewable",
                    value: viewModel.reviewablePhotosCount.formatted(),
                    icon: "checkmark.circle.fill"
                )
            }

            HStack {
                Text(scanStatusLabel)
                    .font(.duckLabel)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.16), in: Capsule(style: .continuous))
                Spacer()
                Text(scanPercentLabel)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.25))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(width: geo.size.width * min(max(scanProgress, 0), 1), height: 6)
                        .animation(.linear(duration: 0.3), value: scanProgress)
                }
            }
            .frame(height: 6)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.accentPrimary, Color.accentDeep, Color.textPrimary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: DuckRadius.l, style: .continuous)
        )
    }

    private var diagnosticsStrip: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Scan details")
                        .font(.duckHeading)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    StatusBadge(
                        title: scanStatusLabel,
                        accent: viewModel.scanState == .paused ? .warning : .accentPrimary
                    )
                }

                HStack(spacing: 10) {
                    DiagnosticsTile(title: "Progress", value: viewModel.scanProgressLabel)
                    DiagnosticsTile(title: "Rate", value: viewModel.scanRateLabel)
                }
            }
            .padding(16)
        }
    }

    @MainActor
    private func exportMLTrainingData() async {
        guard !isExportingMLData else { return }
        isExportingMLData = true
        defer { isExportingMLData = false }

        do {
            let csvURLs = try await PhotoMLBridge.shared.exportTrainingDataToDocuments()
            let databaseURL = try await PhotoMLBridge.shared.exportDatabaseToDocuments()
            mlExportMessage =
                "Exported \(csvURLs.count) training files and \(databaseURL.lastPathComponent) to Files > On My iPhone > PhotoDuck > PhotoDuck-ML-Export."
        } catch {
            mlExportMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private var collageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to review")
                        .font(.duckHeading)
                        .foregroundStyle(Color.textPrimary)
                    Text("\(similarGroups.count) groups, kept separate and easy to compare")
                        .font(.duckCaption)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()

                if similarGroups.count > featuredGroups.count {
                    Button("See all") {
                        showReviewResults = true
                    }
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.accentPrimary)
                }
            }

            ForEach(Array(featuredGroups.enumerated()), id: \.element.id) { index, group in
                NavigationLink {
                    PhotoGroupDetailView(
                        group: group,
                        groupIndex: index,
                        totalGroups: similarGroups.count
                    )
                    .environmentObject(purchaseManager)
                    .environmentObject(deletionManager)
                } label: {
                    DuckCard {
                        SimilarGroupPreviewCard(group: group)
                            .padding(12)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionDock: some View {
        HStack(spacing: 10) {
            Button {
                showReviewResults = true
            } label: {
                Label("Review", systemImage: "rectangle.grid.1x2")
                    .font(.duckButton)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.textSecondary.opacity(0.24), lineWidth: 1)
                    )
            }

            Button {
                if viewModel.scanState == .paused {
                    viewModel.resumeDeepClean()
                } else if similarGroups.isEmpty {
                    Task { await viewModel.scanPhotos() }
                } else {
                    showSwipeMode = true
                }
            } label: {
                Label(
                    viewModel.scanState == .paused ? "Continue" : "Smart Cleanup",
                    systemImage: "sparkles"
                )
                .font(.duckButton)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(LinearGradient.duckPrimaryCTA, in: RoundedRectangle(cornerRadius: DuckRadius.m, style: .continuous))
                .duckPrimaryGlow()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        DuckCard {
            VStack(spacing: 14) {
                PhotoDuckMascotArt(size: 96)

                VStack(spacing: 6) {
                    Text("No similar photos yet")
                        .font(.duckTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text("Run a photo scan from Home or start Smart Cleanup to build the queue.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.textSecondary)
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

private struct HeroStatTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.duckBody.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.duckMicro)
                    .foregroundStyle(.white.opacity(0.8))
                Text(value)
                    .font(.duckStat)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: DuckRadius.m, style: .continuous))
    }
}

private struct DiagnosticsTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.duckLabel)
                .foregroundStyle(Color.textSecondary)
            Text(value)
                .font(.duckStat)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.backgroundBlush, in: RoundedRectangle(cornerRadius: DuckRadius.m, style: .continuous))
    }
}

private struct SimilarGroupPreviewCard: View {
    let group: PhotoGroup
    @State private var images: [String: UIImage] = [:]

    private var leadAssets: [PHAsset] {
        let keeper = group.keeperAssetID.flatMap { keeperID in
            group.assets.first { $0.localIdentifier == keeperID }
        }
        let remaining = group.assets.filter { $0.localIdentifier != keeper?.localIdentifier }
        return Array(([keeper].compactMap { $0 } + remaining).prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(reasonLabel)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.accentPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentPrimary.opacity(0.10), in: Capsule())

                Spacer(minLength: 8)

                Text("\(group.assets.count) photos")
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)

                Image(systemName: "chevron.right")
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.decorPink)
            }

            HStack(spacing: 6) {
                ForEach(leadAssets, id: \.localIdentifier) { asset in
                    thumbnailTile(for: asset)
                        .frame(maxWidth: .infinity)
                        .frame(height: 104)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: group.isAutoCleanEligible ? "sparkles" : "rectangle.stack")
                    .foregroundStyle(group.isAutoCleanEligible ? Color.accentPrimary : Color.warning)
                Text(actionLabel)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
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

    private var actionLabel: String {
        if group.isAutoCleanEligible {
            return "Keep 1 · \(group.deleteCandidateIDs.count) suggested"
        }
        return "Review together only"
    }

    private func loadThumbnails() async {
        for asset in leadAssets {
            let size = CGSize(width: 360, height: 360)
            let image = await asset.loadImage(
                targetSize: size,
                deliveryMode: .opportunistic,
                allowNetwork: true
            )
            if let image {
                images[asset.localIdentifier] = image
            }
        }
    }

    @ViewBuilder
    private func thumbnailTile(for asset: PHAsset) -> some View {
        ZStack {
            if let image = images[asset.localIdentifier] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [Color.decorPink.opacity(0.55), Color.accentPrimary.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay {
                    ProgressView().tint(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.decorPink.opacity(0.55), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if asset.localIdentifier == group.keeperAssetID {
                Image(systemName: "star.fill")
                    .font(.duckMicro.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.accentPrimary, in: Circle())
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
