import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject private var purchaseManager: PurchaseManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Summary bar — shown once any scan completes
                    if viewModel.hasAnyResult {
                        SummaryBar(
                            reclaimableBytes: viewModel.reclaimableBytes,
                            photoGroupCount: viewModel.photoGroups.count,
                            contactMatchCount: viewModel.contactMatches.count,
                            largeFileCount: viewModel.largeFiles.count
                        )
                        .padding(.horizontal)
                    }

                    // Scan cards
                    PhotoScanCard(viewModel: viewModel)
                    ContactScanCard(viewModel: viewModel)
                    FileScanCard(viewModel: viewModel)
                }
                .padding(.vertical)
            }
            .navigationTitle("iOSCleanup")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !purchaseManager.isPurchased {
                        Button("Unlock") {
                            showPaywall = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    @State private var showPaywall = false
}

// MARK: - Summary Bar

private struct SummaryBar: View {
    let reclaimableBytes: Int64
    let photoGroupCount: Int
    let contactMatchCount: Int
    let largeFileCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reclaimable Space")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file))
                .font(.title2.bold())
            HStack(spacing: 12) {
                if photoGroupCount > 0 {
                    Label("\(photoGroupCount) photo groups", systemImage: "photo.on.rectangle.angled")
                }
                if contactMatchCount > 0 {
                    Label("\(contactMatchCount) duplicates", systemImage: "person.2")
                }
                if largeFileCount > 0 {
                    Label("\(largeFileCount) large files", systemImage: "doc.fill")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Photo Scan Card

private struct PhotoScanCard: View {
    @ObservedObject var viewModel: HomeViewModel

    var body: some View {
        ScanCard(
            title: "Similar Photos",
            subtitle: "Find duplicates and burst shots",
            icon: "photo.stack.fill",
            color: .orange,
            state: viewModel.photoScanState,
            resultLabel: resultLabel,
            destination: { PhotoResultsView(groups: viewModel.photoGroups) },
            onScan: { await viewModel.scanPhotos() }
        )
    }

    private var resultLabel: String {
        let n = viewModel.photoGroups.count
        return n == 0 ? "No duplicates found" : "\(n) group\(n == 1 ? "" : "s") found"
    }
}

// MARK: - Contact Scan Card

private struct ContactScanCard: View {
    @ObservedObject var viewModel: HomeViewModel

    var body: some View {
        ScanCard(
            title: "Duplicate Contacts",
            subtitle: "Merge contacts with shared info",
            icon: "person.2.fill",
            color: .green,
            state: viewModel.contactScanState,
            resultLabel: resultLabel,
            destination: { ContactResultsView(matches: viewModel.contactMatches) },
            onScan: { await viewModel.scanContacts() }
        )
    }

    private var resultLabel: String {
        let n = viewModel.contactMatches.count
        return n == 0 ? "No duplicates found" : "\(n) duplicate\(n == 1 ? "" : "s") found"
    }
}

// MARK: - File Scan Card

private struct FileScanCard: View {
    @ObservedObject var viewModel: HomeViewModel

    var body: some View {
        ScanCard(
            title: "Large Files",
            subtitle: "Videos and files over 50 MB",
            icon: "doc.fill",
            color: .purple,
            state: viewModel.fileScanState,
            resultLabel: resultLabel,
            destination: { FileResultsView(files: viewModel.largeFiles) },
            onScan: { await viewModel.scanFiles() }
        )
    }

    private var resultLabel: String {
        let n = viewModel.largeFiles.count
        if n == 0 { return "No large files found" }
        let total = viewModel.largeFiles.reduce(Int64(0)) { $0 + $1.byteSize }
        return "\(n) file\(n == 1 ? "" : "s") — \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}

// MARK: - Generic Scan Card

private struct ScanCard<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let state: HomeViewModel.ScanState
    let resultLabel: String
    @ViewBuilder let destination: () -> Destination
    let onScan: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            switch state {
            case .idle:
                Button(action: { Task { await onScan() } }) {
                    Text("Scan Now")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(color)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

            case .scanning:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

            case .done:
                NavigationLink(destination: destination) {
                    HStack {
                        Text(resultLabel)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(action: { Task { await onScan() } }) {
                    Text("Re-scan")
                        .font(.caption)
                        .foregroundStyle(color)
                }

            case .failed(let message):
                Text("Error: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button(action: { Task { await onScan() } }) {
                    Text("Retry")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(color)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        .padding(.horizontal)
    }
}
