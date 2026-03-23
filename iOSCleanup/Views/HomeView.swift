import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var showPaywall = false
    @State private var showCompletion = false

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)

    var body: some View {
        NavigationStack {
            ZStack {
                bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        headerRow
                        storageRingCard
                        smartCleanButton
                        categoryList
                    }
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .sheet(isPresented: $showCompletion) { CompletionOverlay(viewModel: viewModel) }
        .onChange(of: viewModel.isAllDone) { done in
            if done { showCompletion = true }
        }
    }

    // MARK: - Section 1: Header Row

    private var headerRow: some View {
        HStack {
            HStack(spacing: 10) {
                Image("DuckMascot")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("PhotoDuck")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Free up iPhone space")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            Spacer()
            if !purchaseManager.isPurchased {
                Button("Unlock 🔒") { showPaywall = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    // MARK: - Section 2: Storage Ring Card

    private var storageRingCard: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: viewModel.storageUsedFraction)
                    .stroke(
                        AngularGradient(
                            colors: [Color(red: 1, green: 0.42, blue: 0.67), Color(red: 0.45, green: 0.4, blue: 1)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(Int(viewModel.storageUsedFraction * 100))%")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                    Text("used")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .frame(width: 100, height: 100)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Storage")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text(viewModel.storageTotalStripped)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
                Divider().overlay(Color.white.opacity(0.07))
                HStack(spacing: 0) {
                    storageStatColumn(value: viewModel.storageUsedStripped, label: "Used",
                                      color: .white)
                    storageStatColumn(value: viewModel.storageFreeFormatted, label: "Free",
                                      color: Color(red: 0.29, green: 0.85, blue: 0.6))
                    storageStatColumn(value: viewModel.reclaimableFormatted, label: "Junk",
                                      color: Color(red: 1, green: 0.42, blue: 0.67))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color(white: 1, opacity: 0.08)))
        .padding(.horizontal, 20)
    }

    private func storageStatColumn(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Section 3: Smart Clean Button

    private var smartCleanButton: some View {
        Button {
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await viewModel.scanPhotos() }
                    group.addTask { await viewModel.scanContacts() }
                    group.addTask { await viewModel.scanFiles() }
                }
            }
        } label: {
            Group {
                if viewModel.isAnyScanning {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Scanning…")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Smart Clean")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Scan all categories at once")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.75))
                        }
                        Spacer()
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                            )
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
                }
            }
            .background(
                LinearGradient(
                    colors: [Color(red: 1, green: 0.42, blue: 0.67), Color(red: 0.45, green: 0.4, blue: 1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(viewModel.isAnyScanning ? 0.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .disabled(viewModel.isAnyScanning)
        .padding(.horizontal, 20)
    }

    // MARK: - Section 4: Category List

    private var categoryList: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Categories")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("4 tools")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 24)

            VStack(spacing: 10) {
                CategoryRow(
                    icon: "doc.on.doc",
                    iconColor: Color(red: 1, green: 0.42, blue: 0.67),
                    iconBg: Color(red: 1, green: 0.42, blue: 0.67).opacity(0.15),
                    name: "Duplicates",
                    subtitle: "Near-identical photos",
                    count: viewModel.photoGroups.count,
                    state: viewModel.photoScanState
                ) {
                    PhotoResultsView(groups: viewModel.photoGroups).environmentObject(purchaseManager)
                }
                CategoryRow(
                    icon: "photo.on.rectangle.angled",
                    iconColor: Color(red: 0.98, green: 0.57, blue: 0.24),
                    iconBg: Color(red: 0.98, green: 0.57, blue: 0.24).opacity(0.15),
                    name: "Similar",
                    subtitle: "Visually alike shots",
                    count: viewModel.photoGroups.filter { $0.reason == .visuallySimilar }.count,
                    state: viewModel.photoScanState
                ) {
                    PhotoResultsView(groups: viewModel.photoGroups).environmentObject(purchaseManager)
                }
                CategoryRow(
                    icon: "person.2.fill",
                    iconColor: Color(red: 0.55, green: 0.36, blue: 0.96),
                    iconBg: Color(red: 0.55, green: 0.36, blue: 0.96).opacity(0.15),
                    name: "Contacts",
                    subtitle: "Duplicate entries",
                    count: viewModel.contactMatches.count,
                    state: viewModel.contactScanState
                ) {
                    ContactResultsView(matches: viewModel.contactMatches).environmentObject(purchaseManager)
                }
                CategoryRow(
                    icon: "video.fill",
                    iconColor: Color(red: 0.2, green: 0.83, blue: 0.6),
                    iconBg: Color(red: 0.2, green: 0.83, blue: 0.6).opacity(0.15),
                    name: "Large Videos",
                    subtitle: "Files over 50 MB",
                    count: viewModel.largeFiles.count,
                    state: viewModel.fileScanState
                ) {
                    FileResultsView(files: viewModel.largeFiles).environmentObject(purchaseManager)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - Category Row

private struct CategoryRow<Destination: View>: View {
    let icon: String
    let iconColor: Color
    let iconBg: Color
    let name: String
    let subtitle: String
    let count: Int
    let state: HomeViewModel.ScanState
    @ViewBuilder let destination: () -> Destination

    private var isNavigable: Bool {
        if case .done = state { return count > 0 }
        return false
    }

    var body: some View {
        Group {
            if isNavigable {
                NavigationLink(destination: destination) { rowContent }
            } else {
                rowContent
            }
        }
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(white: 1, opacity: 0.07)))
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14)
                .fill(iconBg)
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(iconColor)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            Spacer()

            VStack(spacing: 4) {
                badgeView
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.2))
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var badgeView: some View {
        switch state {
        case .idle:
            Text("—")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.3))
        case .scanning:
            ProgressView()
                .tint(iconColor)
                .scaleEffect(0.7)
        case .done:
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
            } else {
                Text("0")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.25))
            }
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

// MARK: - HomeViewModel extension

extension HomeViewModel {
    var storageFreeFormatted: String {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }
    var storageTotalStripped: String {
        storageTotalFormatted.replacingOccurrences(of: " total", with: "")
    }
    var storageUsedStripped: String {
        storageUsedFormatted.replacingOccurrences(of: " used", with: "")
    }
}
