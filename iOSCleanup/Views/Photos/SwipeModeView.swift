import SwiftUI
import Photos

struct SwipeModeView: View {
    let groups: [PhotoGroup]
    @EnvironmentObject private var purchaseManager: PurchaseManager
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
                    DuckModeCompletion(viewModel: viewModel, onDismiss: { dismiss() })
                } else {
                    cardStack
                }
            }
            .background(Color.duckBlush.ignoresSafeArea())
            .navigationTitle("Duck Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.duckRose)
                }
            }
        }
    }

    // MARK: - Card Stack

    @State private var dragOffset: CGSize = .zero

    private var swipeThreshold: CGFloat { 100 }

    private var cardStack: some View {
        VStack(spacing: 0) {
            // Tally + progress
            HStack {
                Label("\(viewModel.keptCount) keep", systemImage: "heart.fill")
                    .font(.duckCaption)
                    .foregroundStyle(.green)
                Spacer()
                Label("\(viewModel.duckedCount) ducked", systemImage: "trash.fill")
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckPink)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            DuckProgressBar(progress: viewModel.progress, color: .duckPink)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            Spacer()

            ZStack {
                if let header = currentMonthHeader {
                    Text(header)
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.duckSoftPink.opacity(0.3), in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                }

                ForEach(upcomingEntries.reversed().prefix(2), id: \.id) { entry in
                    if case .asset(let asset, _) = entry {
                        DuckAssetCard(asset: asset)
                            .opacity(entry.id == viewModel.current?.id ? 1 : 0.6)
                            .scaleEffect(entry.id == viewModel.current?.id ? 1 : 0.95)
                    }
                }

                if let current = viewModel.current, case .asset(let asset, _) = current {
                    DuckAssetCard(asset: asset)
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
                        .overlay(swipeIndicators)
                }
            }
            .padding(.horizontal)

            Spacer()

            actionButtons
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
    }

    // MARK: - Swipe indicators

    private var swipeIndicators: some View {
        HStack {
            Text("Duck it ←")
                .font(.duckHeading)
                .foregroundStyle(Color.duckPink)
                .opacity(leftIndicatorOpacity)
                .padding()
            Spacer()
            Text("→ Keep it")
                .font(.duckHeading)
                .foregroundStyle(.green)
                .opacity(rightIndicatorOpacity)
                .padding()
        }
    }

    private var leftIndicatorOpacity: Double {
        guard dragOffset.width < 0 else { return 0 }
        return min(Double(-dragOffset.width) / Double(swipeThreshold), 1)
    }

    private var rightIndicatorOpacity: Double {
        guard dragOffset.width > 0 else { return 0 }
        return min(Double(dragOffset.width) / Double(swipeThreshold), 1)
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 16) {
            DuckOutlineButton(title: "✕ Duck it", color: .duckPink) { swipeLeft() }
            DuckPrimaryButton(title: "✓ Keep it") { swipeRight() }
        }
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
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.duckYellow)
                .frame(width: 160, height: 160)
            Text("All Done! ✦")
                .font(.duckDisplay)
                .foregroundStyle(Color.duckBerry)
            Text("Ducked \(viewModel.duckedCount) photo\(viewModel.duckedCount == 1 ? "" : "s")")
                .font(.duckBody)
                .foregroundStyle(Color.duckRose)
            if let error = viewModel.deleteError {
                Text(error).font(.duckCaption).foregroundStyle(.red)
            }
            Spacer()
            DuckPrimaryButton(title: "✓ Back to Library", action: onDismiss)
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
        }
    }
}

// MARK: - Duck Asset Card

private struct DuckAssetCard: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.duckSoftPink.opacity(0.3))
                    .overlay(ProgressView().tint(Color.duckPink))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.duckPink, lineWidth: 1)
        )
        .shadow(color: Color.duckPink.opacity(0.12), radius: 12, x: 0, y: 6)
        .task { image = await loadImage(for: asset) }
    }

    private func loadImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 600, height: 800),
                contentMode: .aspectFit, options: options
            ) { image, _ in continuation.resume(returning: image) }
        }
    }
}
