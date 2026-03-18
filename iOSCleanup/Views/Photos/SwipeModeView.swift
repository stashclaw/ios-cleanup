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
                    CompletionScreen(viewModel: viewModel, onDismiss: { dismiss() })
                } else {
                    cardStack
                }
            }
            .navigationTitle("Swipe Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Card Stack

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    private var swipeThreshold: CGFloat { 100 }

    private var cardStack: some View {
        ZStack {
            // Month header above card
            if let header = currentMonthHeader {
                VStack {
                    Text(header)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                }
                .padding(.top, 8)
            }

            // Cards (show top 2 for depth)
            ForEach(upcomingEntries.reversed().prefix(2), id: \.id) { entry in
                if case .asset(let asset, _) = entry {
                    AssetCard(asset: asset)
                        .opacity(entry.id == viewModel.current?.id ? 1 : 0.6)
                        .scaleEffect(entry.id == viewModel.current?.id ? 1 : 0.95)
                }
            }

            // Top card with drag
            if let current = viewModel.current, case .asset(let asset, _) = current {
                AssetCard(asset: asset)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width) / 20))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = value.translation
                                isDragging = true
                            }
                            .onEnded { value in
                                withAnimation(.spring()) {
                                    if value.translation.width < -swipeThreshold {
                                        swipeLeft()
                                    } else if value.translation.width > swipeThreshold {
                                        swipeRight()
                                    } else {
                                        dragOffset = .zero
                                    }
                                }
                                isDragging = false
                            }
                    )
                    .overlay(swipeIndicators)
            }

            // Tap buttons below cards
            VStack {
                Spacer()
                actionButtons
                    .padding(.bottom, 32)
            }
        }
        .padding()
    }

    // MARK: - Swipe indicators

    private var swipeIndicators: some View {
        HStack {
            // Left = delete
            Image(systemName: "trash.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
                .opacity(leftIndicatorOpacity)
                .padding()
            Spacer()
            // Right = keep
            Image(systemName: "heart.fill")
                .font(.largeTitle)
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
        HStack(spacing: 40) {
            CircleButton(icon: "trash.fill", color: .red) { swipeLeft() }
            CircleButton(icon: "heart.fill", color: .green) { swipeRight() }
        }
    }

    // MARK: - Helpers

    private var upcomingEntries: [SwipeModeViewModel.QueueEntry] {
        Array(viewModel.queue.dropFirst(viewModel.currentIndex).prefix(3))
    }

    private var currentMonthHeader: String? {
        // Find the most recent header before current index
        let preceding = viewModel.queue.prefix(viewModel.currentIndex + 1)
        return preceding.reversed().compactMap { entry -> String? in
            if case .monthHeader(let s) = entry { return s }
            return nil
        }.first
    }

    private func swipeLeft() {
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = CGSize(width: -500, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            dragOffset = .zero
            viewModel.delete()
        }
    }

    private func swipeRight() {
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = CGSize(width: 500, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            dragOffset = .zero
            viewModel.keep()
        }
    }
}

// MARK: - Completion Screen

private struct CompletionScreen: View {
    @ObservedObject var viewModel: SwipeModeViewModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("All Done!")
                .font(.largeTitle.bold())
            Text("Deleted \(viewModel.deletedCount) photo\(viewModel.deletedCount == 1 ? "" : "s")")
                .font(.title3)
                .foregroundStyle(.secondary)
            if let error = viewModel.deleteError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button(action: onDismiss) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Asset Card

private struct AssetCard: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(ProgressView())
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
        .task {
            image = await loadImage(for: asset)
        }
    }

    private func loadImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 600, height: 800),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in continuation.resume(returning: image) }
        }
    }
}

// MARK: - Circle button

private struct CircleButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(Color.white)
                .padding(20)
                .background(color)
                .clipShape(Circle())
                .shadow(color: color.opacity(0.4), radius: 8, x: 0, y: 4)
        }
    }
}
