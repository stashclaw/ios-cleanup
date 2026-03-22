import SwiftUI
import Photos

struct SwipeModeView: View {
    let groups: [PhotoGroup]
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: SwipeModeViewModel

    init(groups: [PhotoGroup]) {
        self.groups = groups
        _viewModel = StateObject(wrappedValue: SwipeModeViewModel(groups: groups))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isComplete {
                    DuckModeCompletion(
                        viewModel: viewModel,
                        purchaseManager: purchaseManager,
                        deletionManager: deletionManager,
                        onDismiss: { dismiss() }
                    )
                } else {
                    cardStack
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Duck Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.white)
                }
            }
        }
    }

    // MARK: - Card Stack

    @State private var dragOffset: CGSize = .zero

    private var swipeThreshold: CGFloat { 100 }

    private var cardStack: some View {
        ZStack {
            // Background cards (depth effect)
            ForEach(upcomingEntries.reversed().prefix(2), id: \.id) { entry in
                if case .asset(let asset, _) = entry, entry.id != viewModel.current?.id {
                    DuckAssetCard(asset: asset)
                        .scaleEffect(0.93)
                        .opacity(0.5)
                }
            }

            // Side strips — always visible, intensity driven by drag
            HStack(spacing: 0) {
                // Left: red strip (delete)
                ZStack {
                    Color.red.opacity(0.85 + leftStripIntensity * 0.15)
                    Image(systemName: "trash")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .scaleEffect(1 + leftStripIntensity * 0.4)
                }
                .frame(width: 32)
                .frame(maxHeight: .infinity)

                Spacer()

                // Right: green strip (keep)
                ZStack {
                    Color.green.opacity(0.85 + rightStripIntensity * 0.15)
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .scaleEffect(1 + rightStripIntensity * 0.4)
                }
                .frame(width: 32)
                .frame(maxHeight: .infinity)
            }
            .ignoresSafeArea()

            // Current card
            if let current = viewModel.current, case .asset(let asset, _) = current {
                DuckAssetCard(asset: asset, monthHeader: currentMonthHeader)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width) / 20))
                    .gesture(
                        DragGesture()
                            .onChanged { dragOffset = $0.translation }
                            .onEnded { value in
                                withAnimation(.spring()) {
                                    if value.translation.width < -swipeThreshold { swipeLeft() }
                                    else if value.translation.width > swipeThreshold { swipeRight() }
                                    else { dragOffset = .zero }
                                }
                            }
                    )
            }

            // Progress + round buttons overlay
            VStack {
                // Progress strip at top
                HStack {
                    StatusBadge(title: "\(viewModel.reviewedCount) / \(viewModel.totalReviewableCount) reviewed", accent: .duckPink)
                    Spacer()
                    StatusBadge(title: "\(viewModel.remainingCount) left", accent: .duckRose)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)

                DuckProgressBar(progress: viewModel.progress, color: .duckPink)
                    .frame(height: 4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)

                Spacer()

                // Round action buttons
                HStack(spacing: 48) {
                    // Duck it — pink filled
                    Button { swipeLeft() } label: {
                        ZStack {
                            Circle()
                                .fill(Color.duckPink)
                                .frame(width: 64, height: 64)
                            Image(systemName: "trash")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .accessibilityLabel("Duck it")

                    // Keep it — white outlined
                    Button { swipeRight() } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(.white, lineWidth: 2)
                                .frame(width: 64, height: 64)
                            Image(systemName: "heart")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .accessibilityLabel("Keep it")
                }
                .padding(.bottom, 48)
            }
        }
    }

    // MARK: - Strip intensity (0…1)

    private var leftStripIntensity: Double {
        guard dragOffset.width < 0 else { return 0 }
        return min(Double(-dragOffset.width) / Double(swipeThreshold), 1)
    }

    private var rightStripIntensity: Double {
        guard dragOffset.width > 0 else { return 0 }
        return min(Double(dragOffset.width) / Double(swipeThreshold), 1)
    }

    // MARK: - Helpers

    private var upcomingEntries: [SwipeModeViewModel.QueueEntry] {
        Array(viewModel.queue.dropFirst(viewModel.currentIndex).prefix(3))
    }

    private var currentMonthHeader: String? {
        let preceding = viewModel.queue.prefix(viewModel.currentIndex + 1)
        return preceding.reversed().compactMap { entry -> String? in
            if case .monthHeader(let s) = entry { return s }
            return nil
        }.first
    }

    private func swipeLeft() {
        withAnimation(.easeOut(duration: 0.25)) { dragOffset = CGSize(width: -500, height: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { dragOffset = .zero; viewModel.delete() }
    }

    private func swipeRight() {
        withAnimation(.easeOut(duration: 0.25)) { dragOffset = CGSize(width: 500, height: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { dragOffset = .zero; viewModel.keep() }
    }
}

// MARK: - Completion Screen

private struct DuckModeCompletion: View {
    @ObservedObject var viewModel: SwipeModeViewModel
    let purchaseManager: PurchaseManager
    let deletionManager: DeletionManager
    let onDismiss: () -> Void

    @State private var showPaywall = false

    private var pendingGB: String {
        ByteCountFormatter.string(fromByteCount: viewModel.pendingDeleteBytes, countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 32)

                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.duckYellow)
                    .frame(width: 120, height: 120)

                Text("You ducked \(viewModel.duckedCount) photo\(viewModel.duckedCount == 1 ? "" : "s")")
                    .font(.duckTitle)
                    .foregroundStyle(Color.duckBerry)

                if viewModel.pendingDeleteBytes > 0 {
                    Text("\(pendingGB) to free")
                        .font(.duckDisplay)
                        .foregroundStyle(Color.duckPink)
                }

                if let error = viewModel.deleteError {
                    Text(error).font(.duckCaption).foregroundStyle(.red)
                }

                if deletionManager.isDeleting {
                    VStack(spacing: 12) {
                        StatusBadge(title: "Freeing your space...", accent: .duckPink)
                        DuckProgressBar(progress: deletionManager.deletionProgress, color: .duckPink)
                            .frame(height: 12)
                            .padding(.horizontal, 20)
                        Text("\(ByteCountFormatter.string(fromByteCount: deletionManager.bulkProcessedBytes, countStyle: .file)) freed of \(ByteCountFormatter.string(fromByteCount: deletionManager.bulkTotalBytes, countStyle: .file)) total")
                            .font(.duckBody)
                            .foregroundStyle(Color.duckRose)
                        Text("\(deletionManager.bulkProcessedCount) of \(deletionManager.bulkTotalCount) photos")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckBerry)
                    }
                } else {
                    VStack(spacing: 12) {
                        DuckPrimaryButton(title: "Free the space ✦") {
                            guard purchaseManager.isPurchased else { showPaywall = true; return }
                            Task {
                                try? await deletionManager.bulkDelete(assets: viewModel.toDeleteAssets)
                            }
                        }
                        .padding(.horizontal, 32)

                        DuckOutlineButton(title: "Review again", color: .duckRose) {
                            viewModel.resetQueue()
                        }
                        .padding(.horizontal, 20)
                    }
                }

                Spacer(minLength: 32)

                DuckOutlineButton(title: "✓ Back to Library", color: .duckPink) { onDismiss() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }
        }
        .background(Color.duckBlush.ignoresSafeArea())
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }
}

// MARK: - Duck Asset Card

private struct DuckAssetCard: View {
    let asset: PHAsset
    var monthHeader: String? = nil
    @State private var image: UIImage?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Photo — edge-to-edge, scaledToFill
                Group {
                    if let img = image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.gray.opacity(0.3)
                            .overlay(ProgressView().tint(.white))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                // Bottom gradient overlay — 100pt
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)

                // Date + file size
                VStack(alignment: .leading, spacing: 4) {
                    if let header = monthHeader {
                        Text(header)
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if let date = asset.creationDate {
                        Text(Self.dateFormatter.string(from: date))
                            .font(.duckBody.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Text(fileSizeLabel)
                        .font(.duckCaption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 44) // inset from side strips
                .padding(.bottom, 20)
            }
        }
        .task { image = await loadImage(for: asset) }
    }

    private var fileSizeLabel: String {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        for r in resources {
            if let s = r.value(forKey: "fileSize") as? Int64 { total += s }
            else if let s = r.value(forKey: "fileSize") as? Int { total += Int64(s) }
        }
        guard total > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func loadImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 800, height: 1200),
                contentMode: .aspectFill, options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }
}
