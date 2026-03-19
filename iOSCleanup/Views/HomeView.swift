import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var showPaywall = false
    @State private var showCompletion = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    storageCard
                    categoryGrid
                    scanButton
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
            }
            .background(Color.duckBlush.ignoresSafeArea())
            .navigationTitle("PhotoDuck")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !purchaseManager.isPurchased {
                        Button("Unlock 🔒") { showPaywall = true }
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckPink)
                    }
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .sheet(isPresented: $showCompletion) { CompletionOverlay(viewModel: viewModel) }
        .onChange(of: viewModel.isAllDone) { done in
            if done { showCompletion = true }
        }
    }

    // MARK: - Storage Card

    private var storageCard: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 14) {
                LinearGradient(
                    colors: [Color.duckPink, Color.duckRose],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reclaimable Space")
                                .font(.duckCaption)
                                .foregroundStyle(Color.white.opacity(0.85))
                            Text(viewModel.reclaimableFormatted)
                                .font(.duckTitle)
                                .foregroundStyle(Color.white)
                        }
                        Spacer()
                        Image(systemName: "externaldrive.fill")
                            .font(.title2)
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                )

                DuckProgressBar(progress: viewModel.storageUsedFraction, color: .duckPink)
                    .padding(.horizontal, 2)

                HStack {
                    Text(viewModel.storageUsedFormatted)
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                    Spacer()
                    Text(viewModel.storageTotalFormatted)
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckBerry)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Category Grid

    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            CategoryCell(
                icon: "photo.on.rectangle", color: .duckPink,
                name: "Duplicates",
                count: viewModel.photoGroups.count,
                state: viewModel.photoScanState,
                destination: { PhotoResultsView(groups: viewModel.photoGroups).environmentObject(purchaseManager) }
            )
            CategoryCell(
                icon: "rectangle.stack", color: .duckOrange,
                name: "Similar",
                count: viewModel.photoGroups.filter { $0.reason == .visuallySimilar }.count,
                state: viewModel.photoScanState,
                destination: { PhotoResultsView(groups: viewModel.photoGroups).environmentObject(purchaseManager) }
            )
            CategoryCell(
                icon: "person.2.fill", color: .duckRose,
                name: "Contacts",
                count: viewModel.contactMatches.count,
                state: viewModel.contactScanState,
                destination: { ContactResultsView(matches: viewModel.contactMatches).environmentObject(purchaseManager) }
            )
            CategoryCell(
                icon: "video.fill", color: .duckOrange,
                name: "Large Videos",
                count: viewModel.largeFiles.count,
                state: viewModel.fileScanState,
                destination: { FileResultsView(files: viewModel.largeFiles).environmentObject(purchaseManager) }
            )
        }
    }

    // MARK: - Scan button

    private var scanButton: some View {
        VStack(spacing: 8) {
            if viewModel.isAnyScanning {
                HStack(spacing: 10) {
                    ProgressView().tint(Color.duckPink)
                    Text("Scanning…")
                        .font(.duckBody)
                        .foregroundStyle(Color.duckRose)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.duckSoftPink.opacity(0.4), in: RoundedRectangle(cornerRadius: 50))
            } else {
                DuckPrimaryButton(title: "✦ Start Cleaning") {
                    Task {
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask { await viewModel.scanPhotos() }
                            group.addTask { await viewModel.scanContacts() }
                            group.addTask { await viewModel.scanFiles() }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Category Cell

private struct CategoryCell<Destination: View>: View {
    let icon: String
    let color: Color
    let name: String
    let count: Int
    let state: HomeViewModel.ScanState
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        DuckCard {
            Group {
                if case .done = state, count > 0 {
                    NavigationLink(destination: destination) { cellContent }
                } else {
                    cellContent
                }
            }
            .padding(14)
        }
    }

    private var cellContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Spacer()
                if case .done = state {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(Color.duckSoftPink)
                }
            }
            Text(name)
                .font(.duckBody)
                .foregroundStyle(Color.duckBerry)
            stateLabel
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch state {
        case .idle:
            Text("—")
                .font(.duckHeading)
                .foregroundStyle(Color.duckSoftPink)
        case .scanning:
            ProgressView().tint(color).scaleEffect(0.75)
        case .done:
            Text("\(count)")
                .font(Font.custom("FredokaOne-Regular", size: 20))
                .foregroundStyle(count > 0 ? color : Color.duckSoftPink)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
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
                    Text("All cleaned up! ✦")
                        .font(.duckDisplay)
                        .foregroundStyle(Color.duckBerry)
                    Text("Your library is looking fresh.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    StatCell(label: "GB Freed", value: viewModel.reclaimableFormatted, color: .duckPink)
                    StatCell(label: "Photos Removed", value: "\(viewModel.photoGroups.count)", color: .duckOrange)
                    StatCell(label: "Contacts Merged", value: "\(viewModel.contactMatches.count)", color: .duckBerry)
                    StatCell(label: "Videos Compressed", value: "\(viewModel.largeFiles.count)", color: .green)
                }
                .padding(.horizontal)

                DuckPrimaryButton(title: "✦ Back to Library") { dismiss() }
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
