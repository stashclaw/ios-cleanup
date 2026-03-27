import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var showPaywall = false
    @State private var showCompletion = false
    @State private var showSettings = false
    @State private var now = Date()
    @State private var navPath = NavigationPath()
    @State private var pendingNav: NavDest? = nil
    @State private var trashSummaryBytes: Int64 = 0
    @State private var showTrashSummary = false

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        coreStack
            // Phase 2 nav observers (split to avoid type-checker timeout)
            .onChange(of: viewModel.eventRolls.count) { count in
                guard pendingNav == .eventRolls, count > 0 else { return }
                pendingNav = nil; navPath.append(NavDest.eventRolls)
            }
            .onChange(of: viewModel.eventRollScanState) { state in
                guard case .done = state, pendingNav == .eventRolls else { return }
                pendingNav = nil
            }
            .onChange(of: viewModel.videoGroups.count) { count in
                guard pendingNav == .videoDuplicates, count > 0 else { return }
                pendingNav = nil; navPath.append(NavDest.videoDuplicates)
            }
            .onChange(of: viewModel.videoDuplicateScanState) { state in
                guard case .done = state, pendingNav == .videoDuplicates else { return }
                pendingNav = nil
            }
            .onChange(of: viewModel.smartPicks.count) { count in
                guard pendingNav == .smartPicks, count > 0 else { return }
                pendingNav = nil; navPath.append(NavDest.smartPicks)
            }
            .onChange(of: viewModel.smartPicksScanState) { state in
                guard case .done = state, pendingNav == .smartPicks else { return }
                pendingNav = nil
            }
            .onChange(of: viewModel.contactMatches.count) { count in
                guard pendingNav == .contacts, count > 0 else { return }
                pendingNav = nil; navPath.append(NavDest.contacts)
            }
            .onChange(of: viewModel.contactScanState) { state in
                guard case .done = state, pendingNav == .contacts else { return }
                pendingNav = nil
            }
            // Recently Deleted navigation handled directly in the card tap (no pendingNav needed)
    }

    // Split body to avoid Swift type-checker timeout on long modifier chains.
    private var coreStack: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        headerRow
                        topCard          // dual-purpose: scan progress OR storage

                        // "New photos ready" banner — shown after background scan finds new results
                        if viewModel.newPhotosReadyCount > 0 {
                            newPhotosReadyBanner
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if !viewModel.isAnyScanning {
                            scanButton
                        }
                        categoryGrid
                        smartCategoriesSection
                    }
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: NavDest.self) { dest in
                destinationView(for: dest)
            }
            .onAppear { NotificationManager.clearBadge() }
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .sheet(isPresented: $showCompletion) { CompletionOverlay(viewModel: viewModel) }
        .sheet(isPresented: $showSettings) { SettingsView(viewModel: viewModel).environmentObject(purchaseManager) }
        .sheet(isPresented: $showTrashSummary) {
            TrashSummarySheet(bytesFreed: trashSummaryBytes)
                .presentationDetents([.medium])
        }
        .onReceive(NotificationCenter.default.publisher(for: .didFreeBytes)) { notification in
            if let bytes = notification.userInfo?["bytes"] as? Int64, bytes > 0 {
                trashSummaryBytes = bytes
                showTrashSummary = true
            }
        }
        .onChange(of: viewModel.isAllDone) { done in
            if done && viewModel.scanRanThisSession { showCompletion = true }
        }
        .onReceive(ticker) { date in
            if viewModel.isAnyScanning { now = date }
        }
        .onChange(of: viewModel.photoGroups.count) { _ in
            guard let pending = pendingNav else { return }
            if pending == .duplicates {
                let groups = viewModel.photoGroups.filter { $0.reason != .visuallySimilar }
                if !groups.isEmpty { pendingNav = nil; navPath.append(NavDest.duplicates) }
            } else if pending == .similar {
                let groups = viewModel.photoGroups.filter { $0.reason == .visuallySimilar }
                if !groups.isEmpty { pendingNav = nil; navPath.append(NavDest.similar) }
            }
        }
        .onChange(of: viewModel.largeFiles.count) { count in
            guard pendingNav == .largeVideos, count > 0 else { return }
            pendingNav = nil; navPath.append(NavDest.largeVideos)
        }
        .onChange(of: viewModel.blurPhotos.count) { count in
            guard pendingNav == .blurry, count > 0 else { return }
            pendingNav = nil; navPath.append(NavDest.blurry)
        }
        .onChange(of: viewModel.screenshotAssets.count) { count in
            guard pendingNav == .screenshots, count > 0 else { return }
            pendingNav = nil; navPath.append(NavDest.screenshots)
        }
        .onChange(of: viewModel.largePhotos.count) { count in
            guard pendingNav == .largePhotos, count > 0 else { return }
            pendingNav = nil; navPath.append(NavDest.largePhotos)
        }
        .onChange(of: viewModel.photoScanState) { state in
            guard case .done = state else { return }
            if pendingNav == .duplicates || pendingNav == .similar { pendingNav = nil }
        }
        .onChange(of: viewModel.fileScanState) { state in
            guard case .done = state, pendingNav == .largeVideos else { return }
            pendingNav = nil
        }
        .onChange(of: viewModel.blurScanState) { state in
            guard case .done = state, pendingNav == .blurry else { return }
            pendingNav = nil
        }
        .onChange(of: viewModel.screenshotScanState) { state in
            guard case .done = state, pendingNav == .screenshots else { return }
            pendingNav = nil
        }
        .onChange(of: viewModel.largePhotoScanState) { state in
            guard case .done = state, pendingNav == .largePhotos else { return }
            pendingNav = nil
        }
        .onAppear {
            Task { await viewModel.fetchMetadataAssets() }
            viewModel.refreshReviewedGroupKeys()
        }
    }

    // MARK: - Navigation destinations

    @ViewBuilder
    private func destinationView(for dest: NavDest) -> some View {
        switch dest {
        case .duplicates:
            PhotoResultsView(
                title: "Duplicates",
                groups: viewModel.photoGroups.filter { $0.reason != .visuallySimilar }
            )
            .environmentObject(purchaseManager)
            .environmentObject(viewModel as HomeViewModel)
        case .similar:
            PhotoResultsView(
                title: "Similar Photos",
                groups: viewModel.photoGroups.filter { $0.reason == .visuallySimilar }
            )
            .environmentObject(purchaseManager)
            .environmentObject(viewModel as HomeViewModel)
        case .largeVideos:
            FileResultsView()
                .environmentObject(purchaseManager)
                .environmentObject(viewModel as HomeViewModel)
        case .blurry:
            BlurResultsView()
                .environmentObject(purchaseManager)
                .environmentObject(viewModel as HomeViewModel)
        case .screenshots:
            ScreenshotsResultsView()
                .environmentObject(purchaseManager)
                .environmentObject(viewModel as HomeViewModel)
        case .largePhotos:
            LargePhotosResultsView()
                .environmentObject(purchaseManager)
                .environmentObject(viewModel as HomeViewModel)
        case .panoramas:
            MetadataResultsView(
                title: "Panoramas",
                subtitle: "Wide-angle panorama shots",
                icon: "photo.on.rectangle.angled",
                accent: Color(red: 0.18, green: 0.82, blue: 0.82),
                assets: viewModel.panoramaAssets
            )
            .environmentObject(purchaseManager)
            .environmentObject(viewModel as HomeViewModel)
        case .portraitMode:
            MetadataResultsView(
                title: "Portrait Mode",
                subtitle: "Depth-effect portraits",
                icon: "person.crop.rectangle",
                accent: Color(red: 0.72, green: 0.45, blue: 1),
                assets: viewModel.portraitModeAssets
            )
            .environmentObject(purchaseManager)
            .environmentObject(viewModel as HomeViewModel)
        case .livePhotos:
            MetadataResultsView(
                title: "Live Photos",
                subtitle: "Motion + sound photos",
                icon: "livephoto",
                accent: Color(red: 0.98, green: 0.57, blue: 0.24),
                assets: viewModel.livePhotoAssets
            )
            .environmentObject(purchaseManager)
            .environmentObject(viewModel as HomeViewModel)
        case .semantic(let groupId):
            if let group = viewModel.semanticGroups.first(where: { $0.id == groupId }) {
                SemanticResultsView(group: group)
                    .environmentObject(purchaseManager)
            }
        case .eventRolls:
            EventRollResultsView(rolls: viewModel.eventRolls)
                .environmentObject(purchaseManager)
                .environmentObject(viewModel as HomeViewModel)
        case .videoDuplicates:
            VideoGroupResultsView(groups: viewModel.videoGroups)
                .environmentObject(purchaseManager)
                .environmentObject(viewModel as HomeViewModel)
        case .smartPicks:
            SmartPicksResultsView(assets: viewModel.smartPicks,
                                  reasons: viewModel.smartPicksReasons)
                .environmentObject(purchaseManager)
        case .contacts:
            ContactResultsView(matches: viewModel.contactMatches)
                .environmentObject(purchaseManager)
                .environmentObject(viewModel as HomeViewModel)
        case .recentlyDeleted:
            RecentlyDeletedView(viewModel: viewModel)
        case .skippedPhotos:
            SkippedGroupsView()
                .environmentObject(viewModel as HomeViewModel)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Image("photoduck-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 36)
                Text("Free up iPhone space")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            Spacer()
            HStack(spacing: 10) {
                if !purchaseManager.isPurchased {
                    Button("Unlock 🔒") { showPaywall = true }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    // MARK: - Top Card (scan progress during scan, storage otherwise)

    private var topCard: some View {
        HStack(spacing: 20) {
            // Ring — progress ring while scanning, segmented donut when idle
            if viewModel.isAnyScanning {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.06), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: viewModel.overallProgressFraction)
                        .stroke(
                            AngularGradient(
                                colors: [Color(red: 1, green: 0.42, blue: 0.67), Color(red: 0.45, green: 0.4, blue: 1)],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.4), value: viewModel.overallProgressFraction)
                    VStack(spacing: 1) {
                        Text("\(Int(viewModel.overallProgressFraction * 100))")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: Int(viewModel.overallProgressFraction * 100))
                        Text("%")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                .frame(width: 78, height: 78)
            } else if viewModel.photoLibraryBytes > 0 || viewModel.videoLibraryBytes > 0 {
                // Segmented donut: Photos / Videos / Other
                ZStack {
                    storageDonut
                    VStack(spacing: 1) {
                        Text("\(Int(viewModel.storageUsedFraction * 100))")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("%")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                .frame(width: 78, height: 78)
            } else {
                // Fallback single-arc ring (breakdown not yet computed)
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.06), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: viewModel.storageUsedFraction)
                        .stroke(
                            AngularGradient(
                                colors: [Color(red: 1, green: 0.42, blue: 0.67), Color(red: 0.45, green: 0.4, blue: 1)],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("\(Int(viewModel.storageUsedFraction * 100))")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text("%")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                .frame(width: 78, height: 78)
            }

            // Right column
            if viewModel.isAnyScanning {
                scanProgressColumn
            } else {
                storageColumn
            }
        }
        .padding(14)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(white: 1, opacity: 0.08)))
        .padding(.horizontal, 20)
    }

    // MARK: - Segmented storage donut (Canvas-based)

    private static let photoDonutColor = Color(red: 1, green: 0.42, blue: 0.67)   // pink
    private static let videoDonutColor = Color(red: 0.45, green: 0.4, blue: 1)    // purple
    private static let otherDonutColor = Color(red: 0.4,  green: 0.5, blue: 0.65) // blue-gray

    private var storageDonut: some View {
        let totalUsed = max(viewModel.storageCapacity.total - viewModel.storageCapacity.available, 1)
        let photoFrac = Double(viewModel.photoLibraryBytes) / Double(totalUsed)
        let videoFrac = Double(viewModel.videoLibraryBytes) / Double(totalUsed)
        let otherBytes = max(totalUsed - viewModel.photoLibraryBytes - viewModel.videoLibraryBytes, 0)
        let otherFrac  = Double(otherBytes) / Double(totalUsed)

        return Canvas { ctx, size in
            let center    = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius    = min(size.width, size.height) / 2 - 6
            let lineWidth: CGFloat = 10

            // Background track
            var trackPath = Path()
            trackPath.addArc(center: center, radius: radius,
                             startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(trackPath, with: .color(.white.opacity(0.06)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Segments
            let segments: [(frac: Double, color: Color)] = [
                (photoFrac, Self.photoDonutColor),
                (videoFrac, Self.videoDonutColor),
                (otherFrac, Self.otherDonutColor),
            ]
            var startAngle = -90.0
            for seg in segments where seg.frac > 0.01 {
                let sweep = seg.frac * 360.0
                var segPath = Path()
                segPath.addArc(center: center, radius: radius,
                               startAngle: .degrees(startAngle),
                               endAngle: .degrees(startAngle + sweep - 1),
                               clockwise: false)
                ctx.stroke(segPath, with: .color(seg.color),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                startAngle += sweep
            }
        }
    }

    private var scanProgressColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.totalLibraryCount > 0
                 ? "\(viewModel.totalLibraryCount.formatted()) photos"
                 : "Scanning library")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())

            VStack(alignment: .leading, spacing: 4) {
                if viewModel.duplicateProgress.total > 0 {
                    engineProgressRow(
                        label: "Duplicates",
                        progress: viewModel.duplicateProgress,
                        color: Color(red: 1, green: 0.42, blue: 0.67)
                    )
                }
                if viewModel.similarProgress.total > 0 {
                    engineProgressRow(
                        label: "Similar",
                        progress: viewModel.similarProgress,
                        color: Color(red: 0.98, green: 0.57, blue: 0.24)
                    )
                }
                if viewModel.blurProgress.total > 0 {
                    engineProgressRow(
                        label: "Blurry",
                        progress: viewModel.blurProgress,
                        color: Color(red: 0.45, green: 0.4, blue: 1)
                    )
                }
                if let remaining = timeRemainingText {
                    Text(remaining)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }

            Button("Cancel") { viewModel.cancelScan() }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(red: 1, green: 0.42, blue: 0.67).opacity(0.15), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func engineProgressRow(label: String, progress: (completed: Int, total: Int), color: Color) -> some View {
        let pct = Int(Double(progress.completed) / Double(max(1, progress.total)) * 100)
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
            Text("\(pct)%")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: pct)
        }
    }

    private var storageColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total Storage")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.4))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(viewModel.storageTotalStripped)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    if viewModel.totalLibraryCount > 0 {
                        Text("· \(viewModel.totalLibraryCount.formatted()) photos")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                Text("\(viewModel.storageUsedStripped) used")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            Divider().overlay(Color.white.opacity(0.07))
            HStack(spacing: 0) {
                storageStatColumn(value: viewModel.storageUsedStripped, label: "Used", color: .white)
                storageStatColumn(value: viewModel.storageFreeFormatted, label: "Free",
                                  color: Color(red: 0.29, green: 0.85, blue: 0.6))
                storageStatColumn(value: viewModel.reclaimableFormatted, label: "Saveable",
                                  color: Color(red: 1, green: 0.42, blue: 0.67))
            }
            if viewModel.photoLibraryBytes > 0 || viewModel.videoLibraryBytes > 0 {
                Divider().overlay(Color.white.opacity(0.07))
                donutLegend
            }
            if viewModel.totalBytesFreed > 0 || viewModel.totalPhotosDeleted > 0 {
                Divider().overlay(Color.white.opacity(0.07))
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.98, green: 0.57, blue: 0.24))
                    Text("Total Cleaned")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        if viewModel.totalBytesFreed > 0 {
                            Text(viewModel.totalBytesFreedFormatted)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(red: 0.98, green: 0.57, blue: 0.24))
                        }
                        if viewModel.totalPhotosDeleted > 0 {
                            Text("\(viewModel.totalPhotosDeleted) photo\(viewModel.totalPhotosDeleted == 1 ? "" : "s")")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.98, green: 0.57, blue: 0.24).opacity(0.7))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func storageStatColumn(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Donut legend

    private var donutLegend: some View {
        let totalUsed  = max(viewModel.storageCapacity.total - viewModel.storageCapacity.available, 1)
        let otherBytes = max(totalUsed - viewModel.photoLibraryBytes - viewModel.videoLibraryBytes, 0)
        return HStack(spacing: 10) {
            donutLegendItem(color: Self.photoDonutColor, label: "Photos",
                            bytes: viewModel.photoLibraryBytes)
            donutLegendItem(color: Self.videoDonutColor, label: "Videos",
                            bytes: viewModel.videoLibraryBytes)
            donutLegendItem(color: Self.otherDonutColor, label: "Other",
                            bytes: otherBytes)
        }
    }

    private func donutLegendItem(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.45))
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - New Photos Ready Banner

    private var newPhotosReadyBanner: some View {
        Button {
            withAnimation { viewModel.newPhotosReadyCount = 0 }
            navPath.append(NavDest.duplicates)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.white)
                Text("\(viewModel.newPhotosReadyCount) new photo\(viewModel.newPhotosReadyCount == 1 ? "" : "s") ready to review")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation { viewModel.newPhotosReadyCount = 0 }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.97, green: 0.37, blue: 0.64)) // duck pink
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    // MARK: - Scan Button (hidden while scanning — top card takes over)

    private var scanButton: some View {
        VStack(spacing: 8) {
            Button(action: startFullScan) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.hasAnyResult ? "Rescan Library" : "Smart Clean")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                        if let date = viewModel.lastScanDate {
                            Text("Last scanned \(relativeTime(from: date))")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.75))
                        } else {
                            Text("Scan all categories at once")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.75))
                        }
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: viewModel.hasAnyResult ? "arrow.clockwise" : "arrow.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .background(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.42, blue: 0.67), Color(red: 0.45, green: 0.4, blue: 1)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            if viewModel.hasAnyResult {
                HStack {
                    Button {
                        viewModel.clearCache()
                    } label: {
                        Label("Clear Results", systemImage: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    Spacer()
                    Button(action: startIncrementalScan) {
                        Label("Scan for new photos", systemImage: "plus.viewfinder")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Category Grid (2-column, CleanIt-style)

    private var categoryGrid: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Categories")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("12 tools")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 24)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                let duplicateGroups = viewModel.photoGroups.filter { group in
                    group.reason != .visuallySimilar &&
                    !group.assets.contains(where: { viewModel.reviewedAssetIDs.contains($0.localIdentifier) })
                }
                let similarGroups = viewModel.photoGroups.filter { group in
                    group.reason == .visuallySimilar &&
                    !group.assets.contains(where: { viewModel.reviewedAssetIDs.contains($0.localIdentifier) })
                }

                CategoryCard(
                    icon: "doc.on.doc",
                    iconColor: Color(red: 1, green: 0.42, blue: 0.67),
                    name: "Duplicates",
                    subtitle: "Near-identical photos",
                    count: duplicateGroups.count,
                    state: viewModel.photoScanState,
                    scanProgress: viewModel.duplicateProgress,
                    isPaid: false
                ) {
                    if !duplicateGroups.isEmpty {
                        navPath.append(NavDest.duplicates)
                    } else {
                        pendingNav = .duplicates
                        if case .idle = viewModel.photoScanState { Task { await viewModel.scanPhotos() } }
                    }
                }
                CategoryCard(
                    icon: "photo.on.rectangle.angled",
                    iconColor: Color(red: 0.98, green: 0.57, blue: 0.24),
                    name: "Similar",
                    subtitle: "Visually alike shots",
                    count: similarGroups.count,
                    state: viewModel.photoScanState,
                    scanProgress: viewModel.similarProgress,
                    isPaid: false
                ) {
                    if !similarGroups.isEmpty {
                        navPath.append(NavDest.similar)
                    } else {
                        pendingNav = .similar
                        if case .idle = viewModel.photoScanState { Task { await viewModel.scanPhotos() } }
                    }
                }
                CategoryCard(
                    icon: "video.fill",
                    iconColor: Color(red: 0.2, green: 0.83, blue: 0.6),
                    name: "Large Videos",
                    subtitle: "Files over 50 MB",
                    count: viewModel.largeFiles.count,
                    state: viewModel.fileScanState,
                    scanProgress: (0, 0),
                    isPaid: false
                ) {
                    if !viewModel.largeFiles.isEmpty {
                        navPath.append(NavDest.largeVideos)
                    } else {
                        pendingNav = .largeVideos
                        if case .idle = viewModel.fileScanState { Task { await viewModel.scanFiles() } }
                    }
                }
                CategoryCard(
                    icon: "camera.filters",
                    iconColor: Color(red: 0.45, green: 0.4, blue: 1),
                    name: "Blurry",
                    subtitle: "Out-of-focus shots",
                    count: viewModel.blurPhotos.count,
                    state: viewModel.blurScanState,
                    scanProgress: viewModel.blurProgress,
                    isPaid: false
                ) {
                    if !viewModel.blurPhotos.isEmpty {
                        navPath.append(NavDest.blurry)
                    } else {
                        pendingNav = .blurry
                        if case .idle = viewModel.blurScanState { Task { await viewModel.scanBlur() } }
                    }
                }
                CategoryCard(
                    icon: "rectangle.on.rectangle",
                    iconColor: Color(red: 0.18, green: 0.72, blue: 0.95),
                    name: "Screenshots",
                    subtitle: "App & system captures",
                    count: viewModel.screenshotAssets.count,
                    state: viewModel.screenshotScanState,
                    scanProgress: (0, 0),
                    isPaid: false
                ) {
                    if !viewModel.screenshotAssets.isEmpty {
                        navPath.append(NavDest.screenshots)
                    } else {
                        pendingNav = .screenshots
                        if case .idle = viewModel.screenshotScanState { Task { await viewModel.scanScreenshots() } }
                    }
                }
                CategoryCard(
                    icon: "photo.stack",
                    iconColor: Color(red: 0.98, green: 0.75, blue: 0.25),
                    name: "Large Photos",
                    subtitle: "RAW, ProRAW & panoramas",
                    count: viewModel.largePhotos.count,
                    state: viewModel.largePhotoScanState,
                    scanProgress: viewModel.largePhotoProgress,
                    isPaid: false
                ) {
                    if !viewModel.largePhotos.isEmpty {
                        navPath.append(NavDest.largePhotos)
                    } else {
                        pendingNav = .largePhotos
                        if case .idle = viewModel.largePhotoScanState { Task { await viewModel.scanLargePhotos() } }
                    }
                }
                CategoryCard(
                    icon: "photo.on.rectangle.angled",
                    iconColor: Color(red: 0.18, green: 0.82, blue: 0.82),
                    name: "Panoramas",
                    subtitle: "Wide panorama shots",
                    count: viewModel.panoramaCount,
                    state: viewModel.panoramaCount > 0 ? .done : .idle,
                    scanProgress: (0, 0),
                    isPaid: false
                ) {
                    if !viewModel.panoramaAssets.isEmpty {
                        navPath.append(NavDest.panoramas)
                    }
                }
                CategoryCard(
                    icon: "person.crop.rectangle",
                    iconColor: Color(red: 0.72, green: 0.45, blue: 1),
                    name: "Portrait Mode",
                    subtitle: "Depth-effect portraits",
                    count: viewModel.portraitModeCount,
                    state: viewModel.portraitModeCount > 0 ? .done : .idle,
                    scanProgress: (0, 0),
                    isPaid: false
                ) {
                    if !viewModel.portraitModeAssets.isEmpty {
                        navPath.append(NavDest.portraitMode)
                    }
                }
                CategoryCard(
                    icon: "livephoto",
                    iconColor: Color(red: 0.98, green: 0.57, blue: 0.24),
                    name: "Live Photos",
                    subtitle: "Motion + sound photos",
                    count: viewModel.livePhotoCount,
                    state: viewModel.livePhotoCount > 0 ? .done : .idle,
                    scanProgress: (0, 0),
                    isPaid: false
                ) {
                    if !viewModel.livePhotoAssets.isEmpty {
                        navPath.append(NavDest.livePhotos)
                    }
                }
                RecentlyDeletedCard(viewModel: viewModel) {
                    // scanRecentlyDeleted has no await points so it completes synchronously —
                    // the pendingNav/onChange pattern has a timing gap.
                    // Await directly then navigate: guaranteed to open every time.
                    Task { @MainActor in
                        if case .idle = viewModel.recentlyDeletedScanState {
                            await viewModel.scanRecentlyDeleted()
                        }
                        navPath.append(NavDest.recentlyDeleted)
                    }
                }
                CategoryCard(
                    icon: "photo.stack",
                    iconColor: Color(red: 0.4, green: 0.6, blue: 1.0),
                    name: "Event Rolls",
                    subtitle: "Photos from trips & events",
                    count: viewModel.eventRolls.count,
                    state: viewModel.eventRollScanState,
                    scanProgress: (0, 0),
                    isPaid: false
                ) {
                    if !viewModel.eventRolls.isEmpty {
                        navPath.append(NavDest.eventRolls)
                    } else {
                        pendingNav = .eventRolls
                        if case .idle = viewModel.eventRollScanState { Task { await viewModel.scanEventRolls() } }
                    }
                }
                CategoryCard(
                    icon: "video.badge.plus",
                    iconColor: Color(red: 1.0, green: 0.4, blue: 0.3),
                    name: "Duplicate Videos",
                    subtitle: "Similar & repeated clips",
                    count: viewModel.videoGroups.count,
                    state: viewModel.videoDuplicateScanState,
                    scanProgress: (0, 0),
                    isPaid: false
                ) {
                    if !viewModel.videoGroups.isEmpty {
                        navPath.append(NavDest.videoDuplicates)
                    } else {
                        pendingNav = .videoDuplicates
                        if case .idle = viewModel.videoDuplicateScanState { Task { await viewModel.scanVideoDuplicates() } }
                    }
                }
                CategoryCard(
                    icon: "sparkles",
                    iconColor: Color(red: 1, green: 0.8, blue: 0.2),
                    name: "Smart Picks",
                    subtitle: "Lowest quality shots",
                    count: viewModel.smartPicks.count,
                    state: viewModel.smartPicksScanState,
                    scanProgress: (0, 0),
                    isPaid: false
                ) {
                    if !viewModel.smartPicks.isEmpty {
                        navPath.append(NavDest.smartPicks)
                    } else {
                        pendingNav = .smartPicks
                        if case .idle = viewModel.smartPicksScanState {
                            Task { await viewModel.computeSmartPicks() }
                        }
                    }
                }
                CategoryCard(
                    icon: "person.2",
                    iconColor: Color(red: 0.4, green: 0.8, blue: 0.6),
                    name: "Contacts",
                    subtitle: "Duplicate contacts",
                    count: viewModel.contactMatches.count,
                    state: viewModel.contactScanState,
                    scanProgress: (0, 0),
                    isPaid: false
                ) {
                    if !viewModel.contactMatches.isEmpty {
                        navPath.append(NavDest.contacts)
                    } else {
                        pendingNav = .contacts
                        if case .idle = viewModel.contactScanState { Task { await viewModel.scanContacts() } }
                    }
                }

                // Skipped groups — full-width row, only shown when user has skipped groups.
                if !viewModel.skippedPhotoGroups.isEmpty {
                    Button { navPath.append(NavDest.skippedPhotos) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.white.opacity(0.45))
                                .frame(width: 38, height: 38)
                                .background(Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Skipped Groups")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("\(viewModel.skippedPhotoGroups.count) groups set aside · tap to restore")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.white.opacity(0.45))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.25))
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .gridCellColumns(2)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Helpers

    /// Full rescan: wipes cached results first so all engines run from scratch.
    /// Used by the primary "Rescan Library" / "Smart Clean" button.
    private func startFullScan() {
        viewModel.clearCache()
        let task = Task {
            await viewModel.refreshTotalLibraryCount()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await viewModel.scanPhotos() }
                group.addTask { await viewModel.scanFiles() }
                group.addTask { await viewModel.scanBlur() }
                group.addTask { await viewModel.scanScreenshots() }
                group.addTask { await viewModel.scanLargePhotos() }
                group.addTask { await viewModel.scanContacts() }
                group.addTask { await viewModel.scanSemantic() }
                group.addTask { await viewModel.scanEventRolls() }
            }
        }
        viewModel.registerScanTask(task)
    }

    /// Incremental scan: only picks up assets added since the last scan.
    /// Used by "Scan for new photos".
    private func startIncrementalScan() {
        let task = Task {
            await viewModel.refreshTotalLibraryCount()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await viewModel.scanPhotos() }
                group.addTask { await viewModel.scanFiles() }
                group.addTask { await viewModel.scanBlur() }
                group.addTask { await viewModel.scanScreenshots() }
                group.addTask { await viewModel.scanLargePhotos() }
                group.addTask { await viewModel.scanContacts() }
                group.addTask { await viewModel.scanSemantic() }
                group.addTask { await viewModel.scanEventRolls() }
            }
        }
        viewModel.registerScanTask(task)
    }

    private var timeRemainingText: String? {
        guard let start = viewModel.scanStartTime else { return nil }
        let fraction = viewModel.overallProgressFraction
        guard fraction > 0.03 else { return nil }
        let elapsed = now.timeIntervalSince(start)
        let remaining = elapsed / fraction * (1 - fraction)
        if remaining < 8  { return "almost done…" }
        if remaining < 60 { return "~\(Int(remaining))s remaining" }
        let m = Int(remaining) / 60, s = Int(remaining) % 60
        return "~\(m)m \(s)s remaining"
    }

    private func relativeTime(from date: Date) -> String {
        let e = Date().timeIntervalSince(date)
        if e < 60    { return "just now" }
        if e < 3600  { return "\(Int(e / 60))m ago" }
        if e < 86400 { return "\(Int(e / 3600))h ago" }
        return "\(Int(e / 86400))d ago"
    }
}

// MARK: - Smart Categories Section

extension HomeView {
    @ViewBuilder
    var smartCategoriesSection: some View {
        if viewModel.isSemanticVisible {
            VStack(spacing: 10) {
                HStack {
                    Text("Smart Categories")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if case .scanning = viewModel.semanticScanState {
                        ProgressView()
                            .tint(Color(red: 1, green: 0.42, blue: 0.67))
                            .scaleEffect(0.8)
                    } else {
                        Text("\(viewModel.semanticGroups.count) categories")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                }
                .padding(.horizontal, 24)

                VStack(spacing: 10) {
                    ForEach(viewModel.semanticGroups) { group in
                        SemanticCategoryRow(group: group, navPath: $navPath)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct SemanticCategoryRow: View {
    let group: SemanticGroup
    @Binding var navPath: NavigationPath

    private let iconColor = Color(red: 0.4, green: 0.7, blue: 1.0)
    private let iconBg    = Color(red: 0.4, green: 0.7, blue: 1.0).opacity(0.15)

    var body: some View {
        Button {
            navPath.append(NavDest.semantic(group.id))
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(iconBg)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: group.category.icon)
                            .font(.system(size: 20))
                            .foregroundStyle(iconColor)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.category.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("\(group.assets.count) photos")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.4))
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("\(group.assets.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.2))
                }
            }
            .padding(14)
            .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(white: 1, opacity: 0.07)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Navigation destinations

private enum NavDest: Hashable {
    case duplicates, similar, largeVideos, blurry, screenshots, largePhotos
    case panoramas, portraitMode, livePhotos
    case semantic(UUID)   // UUID of the SemanticGroup
    case eventRolls
    case videoDuplicates
    case smartPicks
    case contacts
    case recentlyDeleted
    case skippedPhotos
}

// MARK: - Category Card (2-column grid tile)

private struct CategoryCard: View {
    let icon: String
    let iconColor: Color
    let name: String
    let subtitle: String
    let count: Int
    let state: HomeViewModel.ScanState
    let scanProgress: (completed: Int, total: Int)
    let isPaid: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            cardContent
        }
        .buttonStyle(.plain)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(white: 1, opacity: 0.07)))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: count badge (+ lock) on right
            HStack(alignment: .top) {
                Spacer()
                HStack(spacing: 4) {
                    countBadge
                    if isPaid {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // Icon centered
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 14)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 22))
                            .foregroundStyle(iconColor)
                    )
                Spacer()
            }
            .padding(.vertical, 14)

            // Name + subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var countBadge: some View {
        switch state {
        case .idle:
            Text("—")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.3))
        case .scanning:
            if count > 0 {
                // Live count — animates upward as results arrive
                Text(count.formatted())
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(iconColor, in: Capsule())
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: count)
            } else {
                ProgressView()
                    .tint(iconColor)
                    .scaleEffect(0.75)
                    .frame(width: 28, height: 20)
            }
        case .done:
            let label = count > 0 ? count.formatted() : "0"
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(count > 0 ? .white : Color.white.opacity(0.3))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(count > 0 ? iconColor : Color.white.opacity(0.07), in: Capsule())
                .contentTransition(.numericText())
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Completion Overlay

private struct CompletionOverlay: View {
    @ObservedObject var viewModel: HomeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.duckYellow)
                    .frame(width: 160, height: 160)
                    .padding(.top, 40)

                VStack(spacing: 6) {
                    Text("Scan complete! ✦")
                        .font(.duckDisplay)
                        .foregroundStyle(Color.duckBerry)
                    Text("Here's what we found in your library.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    StatCell(label: "Reclaimable", value: viewModel.reclaimableFormatted, color: .duckPink)
                    let dupCount = viewModel.photoGroups.filter { $0.reason != .visuallySimilar }.count
                    StatCell(label: "Duplicate Groups", value: "\(dupCount)", color: .duckOrange)
                    StatCell(label: "Similar Groups", value: "\(viewModel.photoGroups.filter { $0.reason == .visuallySimilar }.count)", color: Color(red: 0.45, green: 0.4, blue: 1))
                    StatCell(label: "Blurry Photos", value: "\(viewModel.blurPhotos.count)", color: .green)
                }
                .padding(.horizontal)

                Text("Tap any category below to review and delete.")
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                DuckPrimaryButton(title: "✦ Review Results") { dismiss() }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
            }
        }
        .background(Color.duckCream.ignoresSafeArea())
    }
}

private struct StatCell: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        DuckCard {
            VStack(spacing: 4) {
                Text(value)
                    .font(Font.custom("FredokaOne-Regular", size: 20))
                    .foregroundStyle(color)
                Text(label)
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckBerry)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Recently Deleted Card

private struct RecentlyDeletedCard: View {
    @ObservedObject var viewModel: HomeViewModel
    let onTap: () -> Void

    private let iconColor = Color(red: 1, green: 0.6, blue: 0.2)

    var body: some View {
        Button {
            guard case .scanning = viewModel.recentlyDeletedScanState else {
                onTap()
                return
            }
        } label: {
            cardContent
        }
        .disabled({
            if case .scanning = viewModel.recentlyDeletedScanState { return true }
            return false
        }())
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(white: 1, opacity: 0.07)))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Spacer()
                badgeView
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 14)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(iconColor)
                    )
                Spacer()
            }
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recently Deleted")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Recover space now")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var badgeView: some View {
        switch viewModel.recentlyDeletedScanState {
        case .idle:
            Text("Tap to scan")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.3))
        case .scanning:
            ProgressView()
                .tint(iconColor)
                .scaleEffect(0.75)
                .frame(width: 28, height: 20)
        case .done:
            let count = viewModel.recentlyDeletedPhotos.count
            Text(count > 0 ? count.formatted() : "0")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(count > 0 ? .white : Color.white.opacity(0.3))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(count > 0 ? iconColor : Color.white.opacity(0.07), in: Capsule())
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
        }
    }
}

// MARK: - HomeViewModel display extensions

extension HomeViewModel {
    var storageFreeFormatted: String {
        ByteCountFormatter.string(fromByteCount: storageCapacity.available, countStyle: .file)
    }
    var storageTotalStripped: String {
        storageTotalFormatted.replacingOccurrences(of: " total", with: "")
    }
    var storageUsedStripped: String {
        storageUsedFormatted.replacingOccurrences(of: " used", with: "")
    }
}
