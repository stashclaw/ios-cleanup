@preconcurrency import AVFoundation
import AVKit
import Photos
import SwiftUI
import UIKit

enum FileDeletionErrorPolicy {
    static func isBenignCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain
            && nsError.code == PHPhotosError.Code.userCancelled.rawValue
    }
}

enum LargeVideoOrganization: String, CaseIterable, Identifiable {
    case size = "Size"
    case year = "Year"
    case month = "Month"

    var id: Self { self }
}

enum LargeVideoReviewLayout {
    case list
    case thumbnails
}

struct LargeVideoReviewSection: Identifiable {
    let id: String
    let title: String?
    let files: [LargeFile]
}

enum LargeVideoReviewOrganizer {
    static func sections(
        for files: [LargeFile],
        organization: LargeVideoOrganization,
        calendar: Calendar = .current
    ) -> [LargeVideoReviewSection] {
        switch organization {
        case .size:
            return [
                LargeVideoReviewSection(
                    id: "size",
                    title: nil,
                    files: sortedBySize(files)
                )
            ]
        case .year:
            return datedSections(
                files: files,
                calendar: calendar,
                includesMonth: false
            )
        case .month:
            return datedSections(
                files: files,
                calendar: calendar,
                includesMonth: true
            )
        }
    }

    private static func sortedBySize(_ files: [LargeFile]) -> [LargeFile] {
        files.sorted { lhs, rhs in
            if lhs.byteSize != rhs.byteSize {
                return lhs.byteSize > rhs.byteSize
            }
            if lhs.creationDate != rhs.creationDate {
                return (lhs.creationDate ?? .distantPast)
                    > (rhs.creationDate ?? .distantPast)
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName)
                == .orderedAscending
        }
    }

    private static func datedSections(
        files: [LargeFile],
        calendar: Calendar,
        includesMonth: Bool
    ) -> [LargeVideoReviewSection] {
        struct Bucket {
            let id: String
            let title: String
            let sortDate: Date?
            var files: [LargeFile]
        }

        var buckets: [String: Bucket] = [:]
        for file in files {
            guard let date = file.creationDate else {
                let id = "unknown-date"
                var bucket = buckets[id] ?? Bucket(
                    id: id,
                    title: "Unknown Date",
                    sortDate: nil,
                    files: []
                )
                bucket.files.append(file)
                buckets[id] = bucket
                continue
            }

            let components = calendar.dateComponents(
                includesMonth ? [.year, .month] : [.year],
                from: date
            )
            guard let year = components.year else { continue }
            let month = includesMonth ? (components.month ?? 1) : 1
            let startDate = calendar.date(
                from: DateComponents(year: year, month: month, day: 1)
            )
            let id = includesMonth
                ? String(format: "month-%04d-%02d", year, month)
                : "year-\(year)"
            let title = includesMonth
                ? (startDate?.formatted(.dateTime.month(.wide).year()) ?? "\(year)")
                : "\(year)"
            var bucket = buckets[id] ?? Bucket(
                id: id,
                title: title,
                sortDate: startDate,
                files: []
            )
            bucket.files.append(file)
            buckets[id] = bucket
        }

        return buckets.values
            .sorted {
                ($0.sortDate ?? .distantPast) > ($1.sortDate ?? .distantPast)
            }
            .map {
                LargeVideoReviewSection(
                    id: $0.id,
                    title: $0.title,
                    files: sortedBySize($0.files)
                )
            }
    }
}

@MainActor
final class LargeVideoReviewSectionMemo {
    private struct FileSignature: Equatable {
        let id: UUID
        let assetID: String
        let displayName: String
        let byteSize: Int64
        let byteSizeIsEstimated: Bool
        let creationDate: Date?
    }

    private var signatures: [FileSignature] = []
    private var hiddenFileIDs = Set<UUID>()
    private var organization: LargeVideoOrganization?
    private var cachedSections: [LargeVideoReviewSection] = []
    private(set) var recomputationCount = 0

    func sections(
        for files: [LargeFile],
        hiddenFileIDs: Set<UUID>,
        organization: LargeVideoOrganization
    ) -> [LargeVideoReviewSection] {
        let nextSignatures = files.map {
            FileSignature(
                id: $0.id,
                assetID: $0.photoAsset.localIdentifier,
                displayName: $0.displayName,
                byteSize: $0.byteSize,
                byteSizeIsEstimated: $0.byteSizeIsEstimated,
                creationDate: $0.creationDate
            )
        }
        guard nextSignatures != signatures
            || hiddenFileIDs != self.hiddenFileIDs
            || organization != self.organization else {
            return cachedSections
        }

        signatures = nextSignatures
        self.hiddenFileIDs = hiddenFileIDs
        self.organization = organization
        let visibleFiles = files.filter {
            !hiddenFileIDs.contains($0.id)
        }
        recomputationCount += 1
        cachedSections = LargeVideoReviewOrganizer.sections(
            for: visibleFiles,
            organization: organization
        )
        return cachedSections
    }
}

enum LargeVideoExportSelection {
    static func selectedFiles(
        in files: [LargeFile],
        assetIDs: Set<String>
    ) -> [LargeFile] {
        files.filter {
            assetIDs.contains($0.photoAsset.localIdentifier)
        }
    }

    static func reconciledAssetIDs(
        _ assetIDs: Set<String>,
        with files: [LargeFile],
        resultsAreAuthoritative: Bool = true
    ) -> Set<String> {
        guard resultsAreAuthoritative else {
            return assetIDs
        }
        return assetIDs.intersection(
            files.map { $0.photoAsset.localIdentifier }
        )
    }

    static func totalBytes(in files: [LargeFile]) -> Int64 {
        files.reduce(into: Int64(0)) { total, file in
            let addition = total.addingReportingOverflow(file.byteSize)
            total = addition.overflow ? .max : addition.partialValue
        }
    }
}

struct FileResultsView: View {
    let files: [LargeFile]
    let scanState: HomeViewModel.ScanState
    let scanProgress: FileScanProgress
    let onRefresh: (() async -> Void)?
    let onAssetDeleted: ((String) -> Void)?

    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @EnvironmentObject private var exportAlbum: ExportAlbumStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var compressionTarget: LargeFile?
    @State private var playbackTarget: LargeFile?
    @State private var showPaywall = false
    @State private var showExportAlbum = false
    @State private var organization: LargeVideoOrganization = .size
    @State private var reviewLayout: LargeVideoReviewLayout = .list
    @State private var reviewSectionMemo =
        LargeVideoReviewSectionMemo()
    @State private var deletionError: String?
    @State private var hiddenFileIDs = Set<UUID>()
    @State private var pendingPhotoFileIDs = Set<UUID>()
    @State private var isSelectingForExport = false
    @State private var selectedVideoAssetIDs = Set<String>()
    @State private var pendingExternalExportFiles: [LargeFile] = []
    @State private var showExternalFolderPicker = false
    @State private var isExportingSelection = false
    @State private var selectedExportProgressStore =
        ExternalPhotoExportProgressStore()
    @State private var selectedExportTask: Task<Void, Never>?
    @State private var selectedExportLiveActivity =
        ExportLiveActivityController()
    @State private var exportError: String?
    @State private var exportAlbumConfirmation: String?
    @State private var exportAlbumConfirmationTask: Task<Void, Never>?
    @State private var completedExportTitle = "Export Complete"
    @State private var completedExportMessage: String?

    init(
        files: [LargeFile],
        scanState: HomeViewModel.ScanState = .completed,
        scanProgress: FileScanProgress = .idle,
        onRefresh: (() async -> Void)? = nil,
        onAssetDeleted: ((String) -> Void)? = nil
    ) {
        self.files = files
        self.scanState = scanState
        self.scanProgress = scanProgress
        self.onRefresh = onRefresh
        self.onAssetDeleted = onAssetDeleted
    }

    private var visibleFiles: [LargeFile] {
        files.filter { !hiddenFileIDs.contains($0.id) }
    }

    private var visibleAssetIDs: Set<String> {
        Set(visibleFiles.map { $0.photoAsset.localIdentifier })
    }

    private var selectedVideoFiles: [LargeFile] {
        LargeVideoExportSelection.selectedFiles(
            in: visibleFiles,
            assetIDs: selectedVideoAssetIDs
        )
    }

    private var selectedVideoBytes: Int64 {
        LargeVideoExportSelection.totalBytes(in: selectedVideoFiles)
    }

    private var selectedVideoSizeIsEstimated: Bool {
        selectedVideoFiles.contains { $0.byteSizeIsEstimated }
    }

    private var allVisibleVideosAreSelected: Bool {
        !visibleAssetIDs.isEmpty
            && selectedVideoAssetIDs == visibleAssetIDs
    }

    private var selectedUnqueuedAssets: [PHAsset] {
        selectedVideoFiles.compactMap { file in
            let asset = file.photoAsset
            return exportAlbum.contains(asset.localIdentifier) ? nil : asset
        }
    }

    private var reviewSections: [LargeVideoReviewSection] {
        reviewSectionMemo.sections(
            for: files,
            hiddenFileIDs: hiddenFileIDs,
            organization: organization
        )
    }

    var body: some View {
        refreshableContent
            .navigationTitle("Large Videos")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(
                isExportingSelection || isSelectingForExport
            )
            .toolbar {
                if isSelectingForExport, !visibleFiles.isEmpty {
                    // The back chevron is hidden while selecting, so Cancel
                    // owns the leading slot and Done confirms without
                    // discarding the selection.
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            cancelExportSelection()
                        }
                        .disabled(isExportingSelection)
                        .accessibilityHint(
                            "Leaves selection mode and clears the current video selection"
                        )
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            finishExportSelection()
                        }
                        .disabled(isExportingSelection)
                        .accessibilityHint(
                            "Leaves selection mode and keeps the current video selection"
                        )
                    }
                } else if !visibleFiles.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Select") {
                            beginExportSelection()
                        }
                        .disabled(isExportingSelection)
                        .accessibilityHint(
                            "Selects multiple videos for export"
                        )
                    }
                }
                if onRefresh != nil, !isSelectingForExport {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: refreshVideos) {
                            if scanState == .scanning {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(scanState == .scanning)
                        .accessibilityLabel("Scan videos again")
                        .accessibilityHint("Checks the Photos library again for videos over 100 megabytes")
                    }
                }
            }
            .navigationDestination(isPresented: $showExportAlbum) {
                ExportAlbumView()
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectingForExport, !visibleFiles.isEmpty {
                    selectedExportActionBar
                } else if exportAlbum.count > 0, !visibleFiles.isEmpty {
                    continueToExportBar
                }
            }
            .sheet(item: $compressionTarget) { file in
                VideoCompressionView(
                    file: file,
                    onOriginalDeleted: {
                        // The original is in Recently Deleted; drop the stale
                        // row and parent result directly. A full video-library
                        // rescan would redo unrelated PhotoKit work.
                        hiddenFileIDs.insert(file.id)
                        onAssetDeleted?(
                            file.photoAsset.localIdentifier
                        )
                    }
                )
                .environmentObject(purchaseManager)
            }
            .sheet(item: $playbackTarget) { file in
                LargeVideoPlayerView(file: file)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView().environmentObject(purchaseManager)
            }
            .sheet(isPresented: $showExternalFolderPicker) {
                ExternalFolderPicker { directoryURL in
                    let explicitFiles = pendingExternalExportFiles
                    showExternalFolderPicker = false
                    selectedExportTask = Task {
                        await exportSelectedVideos(
                            explicitFiles,
                            to: directoryURL
                        )
                    }
                }
            }
            .alert(
                "Couldn’t Delete Video",
                isPresented: Binding(
                    get: { deletionError != nil },
                    set: { if !$0 { deletionError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { deletionError = nil }
            } message: {
                Text(deletionError ?? "")
            }
            .alert(
                "Export Couldn’t Finish",
                isPresented: Binding(
                    get: { exportError != nil },
                    set: { if !$0 { exportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
            .alert(
                completedExportTitle,
                isPresented: Binding(
                    get: { completedExportMessage != nil },
                    set: { if !$0 { completedExportMessage = nil } }
                )
            ) {
                Button("Done", role: .cancel) {
                    completedExportMessage = nil
                }
            } message: {
                Text(completedExportMessage ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
                showPaywall = false
            }
            .onChange(of: scenePhase) { phase in
                guard isExportingSelection else { return }
                switch phase {
                case .background:
                    // Keep copying under the active UIKit background assertion.
                    // Only its expiration handler represents a real pause.
                    break
                case .active:
                    guard let selectedExportProgress =
                            selectedExportProgressStore.progress else {
                        return
                    }
                    Task { @MainActor in
                        await selectedExportLiveActivity.resume(
                            with: selectedExportProgress
                        )
                    }
                default:
                    break
                }
            }
            .onChange(of: Set(files.map(\.id))) { availableIDs in
                // Parent data remains authoritative. Once a refresh removes an
                // item, discard its local optimistic-hide marker.
                hiddenFileIDs.formIntersection(availableIDs)
                pendingPhotoFileIDs.formIntersection(availableIDs)
                reconcileExportSelection(
                    resultsAreAuthoritative: scanState != .scanning
                )
            }
            .onChange(of: scanState) { state in
                guard state != .scanning else { return }
                reconcileExportSelection(resultsAreAuthoritative: true)
            }
            .onChange(of: deletionManager.undoEventID) { _ in
                restoreUndonePhotoLibraryFiles()
            }
            .onChange(of: deletionManager.lastDeletionError) { error in
                guard error != nil else { return }
                hiddenFileIDs.subtract(pendingPhotoFileIDs)
                pendingPhotoFileIDs.removeAll()
            }
            .onChange(of: deletionManager.lastCommittedToastID) { toastID in
                guard toastID != nil else { return }
                pendingPhotoFileIDs.removeAll()
            }
    }

    @ViewBuilder
    private var refreshableContent: some View {
        if let onRefresh, !isSelectingForExport {
            resultsContent
                .refreshable {
                    await onRefresh()
                }
        } else {
            resultsContent
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if scanState == .permissionRequired {
            ScrollView {
                EmptyStateView(
                    title: "Photos Access Needed",
                    icon: "exclamationmark.triangle.fill",
                    message: "PhotoDuck can't look for large videos until you allow photo access in Settings.",
                    style: .neutral,
                    actionTitle: "Open Settings",
                    action: {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                )
                .frame(maxWidth: .infinity)
            }
            .background(Color.backgroundBlush.ignoresSafeArea())
        } else if scanState == .scanning, visibleFiles.isEmpty {
            ScrollView {
                DuckCard {
                    VStack(spacing: 14) {
                        if let progress = scanProgress.progressFraction {
                            ProgressView(value: progress)
                                .progressViewStyle(.circular)
                                .controlSize(.large)
                                .tint(Color.accentPrimary)
                        } else {
                            ProgressView()
                                .controlSize(.large)
                                .tint(Color.accentPrimary)
                        }
                        Text("Scanning videos…")
                            .font(.duckHeading)
                            .foregroundStyle(Color.textPrimary)
                        Text(
                            scanProgress.statusMessage
                                ?? "Checking your Photos library for videos over 100 MB."
                        )
                            .font(.duckCaption)
                            .foregroundStyle(Color.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
                .padding(16)
            }
            .background(Color.backgroundBlush.ignoresSafeArea())
        } else if visibleFiles.isEmpty {
            let retryTitle: String? = onRefresh == nil ? nil : "Scan Videos Again"
            let retryAction: (() -> Void)? = onRefresh == nil
                ? nil
                : { refreshVideos() }
            ScrollView {
                EmptyStateView(
                    title: "No Large Videos",
                    icon: "doc.fill",
                    message: "No videos over 100 MB were found.",
                    actionTitle: retryTitle,
                    action: retryAction
                )
                .frame(maxWidth: .infinity)
            }
            .background(Color.backgroundBlush.ignoresSafeArea())
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if scanState == .scanning {
                        scanningBanner
                    } else if scanProgress.isComplete,
                              scanProgress.totalVideoCount > 0 {
                        completedScanBanner
                    }
                    reviewControls
                    // One entry point into selection: the toolbar Select
                    // button. While selecting, the bottom bar owns the count,
                    // Select All, and the export actions.
                    if !isSelectingForExport {
                        exportGuidanceCard
                    }
                    ForEach(reviewSections) { section in
                        reviewSection(section)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .background(Color.backgroundBlush.ignoresSafeArea())
        }
    }

    private var reviewControls: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Browse by")
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    HStack(spacing: 4) {
                        layoutButton(
                            layout: .list,
                            systemImage: "list.bullet",
                            accessibilityLabel: "List view"
                        )
                        layoutButton(
                            layout: .thumbnails,
                            systemImage: "square.grid.2x2",
                            accessibilityLabel: "Thumbnail view"
                        )
                    }
                }

                Picker("Browse by", selection: $organization) {
                    ForEach(LargeVideoOrganization.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Size sorts largest first. Year and Month group videos by capture date.")
            }
            .padding(12)
        }
    }

    private func layoutButton(
        layout: LargeVideoReviewLayout,
        systemImage: String,
        accessibilityLabel: String
    ) -> some View {
        Button {
            reviewLayout = layout
        } label: {
            Image(systemName: systemImage)
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(
                    reviewLayout == layout ? Color.white : Color.textSecondary
                )
                .frame(width: 38, height: 32)
                .background(
                    reviewLayout == layout
                        ? Color.accentPrimary
                        : Color.surfaceElevated,
                    in: RoundedRectangle(
                        cornerRadius: DuckRadius.s,
                        style: .continuous
                    )
                )
                // Keep the chip compact but give it a full 44pt hit area.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(reviewLayout == layout ? .isSelected : [])
    }

    @ViewBuilder
    private func reviewSection(_ section: LargeVideoReviewSection) -> some View {
        if let title = section.title {
            HStack {
                Text(title)
                    .font(.duckHeading)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(section.files.count)")
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }

        switch reviewLayout {
        case .list:
            ForEach(section.files) { file in
                DuckCard {
                    FileRow(
                        file: file,
                        purchaseManager: purchaseManager,
                        isQueuedForExport: isQueuedForExport(file),
                        isSelectingForExport: isSelectingForExport,
                        isSelectedForExport: isSelectedForExport(file),
                        isDeleting: isDeleting(file),
                        onPlay: { playbackTarget = file },
                        onToggleExportSelection: {
                            toggleExportSelection(for: file)
                        },
                        onAddToExport: {
                            addToExportAlbum(file.photoAsset)
                        },
                        onDelete: { requestDeletion(of: file) },
                        onCompress: { requestCompression(of: file) }
                    )
                    .padding(14)
                }
            }
        case .thumbnails:
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(section.files) { file in
                    LargeVideoGridCard(
                        file: file,
                        purchaseManager: purchaseManager,
                        isQueuedForExport: isQueuedForExport(file),
                        isSelectingForExport: isSelectingForExport,
                        isSelectedForExport: isSelectedForExport(file),
                        isDeleting: isDeleting(file),
                        onPlay: { playbackTarget = file },
                        onToggleExportSelection: {
                            toggleExportSelection(for: file)
                        },
                        onAddToExport: {
                            addToExportAlbum(file.photoAsset)
                        },
                        onDelete: { requestDeletion(of: file) },
                        onCompress: { requestCompression(of: file) }
                    )
                }
            }
        }
    }

    private func isQueuedForExport(_ file: LargeFile) -> Bool {
        exportAlbum.contains(file.photoAsset.localIdentifier)
    }

    private func isSelectedForExport(_ file: LargeFile) -> Bool {
        selectedVideoAssetIDs.contains(
            file.photoAsset.localIdentifier
        )
    }

    private func isDeleting(_ file: LargeFile) -> Bool {
        pendingPhotoFileIDs.contains(file.id)
    }

    private func requestCompression(of file: LargeFile) {
        guard purchaseManager.isPurchased else {
            showPaywall = true
            return
        }
        compressionTarget = file
    }

    private var scanningBanner: some View {
        DuckCard {
            HStack(spacing: 12) {
                if let progress = scanProgress.progressFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .tint(Color.accentPrimary)
                } else {
                    ProgressView()
                        .tint(Color.accentPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Refreshing large videos")
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(
                        scanProgress.statusMessage
                            ?? "Current results stay available while PhotoDuck checks again."
                    )
                        .font(.duckMicro)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
            }
            .padding(12)
        }
        .accessibilityElement(children: .combine)
    }

    private var completedScanBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.success)
            Text(
                scanProgress.statusMessage
                    ?? "Video scan complete"
            )
                .font(.duckMicro)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var exportGuidanceCard: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "Move big videos somewhere safe",
                    systemImage: "externaldrive.fill.badge.plus"
                )
                .font(.duckBody.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

                Text(
                    "Tap Select at the top to choose videos, then copy them to a drive or Files folder. PhotoDuck copies and verifies the original files without deleting anything."
                )
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(14)
        }
        .accessibilityElement(children: .combine)
    }

    private var selectedExportActionBar: some View {
        VStack(spacing: 8) {
            if isExportingSelection {
                ExternalPhotoExportProgressStatusView(
                    store: selectedExportProgressStore,
                    onCancel: {
                        selectedExportTask?.cancel()
                    },
                    cancellationHelp:
                        "Cancel stops the current item; verified videos remain on the drive. Choose the same destination again to resume an interruption."
                )
            } else {
                if let exportAlbumConfirmation {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.success)
                        Text(exportAlbumConfirmation)
                            .font(.duckMicro)
                            .foregroundStyle(Color.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedVideoCountLabel)
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text(
                            selectedVideoFiles.isEmpty
                                ? "Tap a video to choose it."
                                : selectedVideoSizeLabel
                        )
                            .font(.duckMicro)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    if !selectedVideoFiles.isEmpty {
                        Button(
                            allVisibleVideosAreSelected
                                ? "Deselect All"
                                : "Select All"
                        ) {
                            toggleSelectAllVisibleVideos()
                        }
                        .font(.duckCaption.weight(.semibold))
                    }
                }

                // With nothing selected the bar offers a real, enabled action
                // instead of a disabled button telling the user to select.
                if selectedVideoFiles.isEmpty {
                    Button {
                        toggleSelectAllVisibleVideos()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Select All \(visibleFiles.count)")
                        }
                        .font(.duckButton)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            LinearGradient.duckPrimaryCTA,
                            in: RoundedRectangle(
                                cornerRadius: DuckRadius.m,
                                style: .continuous
                            )
                        )
                        .duckPrimaryGlow()
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(
                        "Selects every video in the current list"
                    )
                } else {
                    Button {
                        beginExternalExport()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive.badge.plus")
                            Text(exportSelectedTitle)
                        }
                        .font(.duckButton)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            LinearGradient.duckPrimaryCTA,
                            in: RoundedRectangle(
                                cornerRadius: DuckRadius.m,
                                style: .continuous
                            )
                        )
                        .duckPrimaryGlow()
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(
                        "Choose an external drive or Files folder for only the selected videos"
                    )

                    Button {
                        addSelectedVideosToExportAlbum()
                    } label: {
                        Label(
                            addSelectedToAlbumTitle,
                            systemImage: "tray.and.arrow.down"
                        )
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(
                            selectedUnqueuedAssets.isEmpty
                                ? Color.textSecondary.opacity(0.6)
                                : Color.accentPrimary
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedUnqueuedAssets.isEmpty)
                    .accessibilityHint(
                        "Saves only the selected videos in Export Album for later"
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var continueToExportBar: some View {
        Button {
            showExportAlbum = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Continue to Export")
                        .font(.duckButton)
                    Text("\(exportAlbum.count) \(exportAlbum.count == 1 ? "item" : "items") ready")
                        .font(.duckMicro)
                        .opacity(0.82)
                }
                Spacer()
                Image(systemName: "chevron.right")
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                LinearGradient.duckPrimaryCTA,
                in: RoundedRectangle(
                    cornerRadius: DuckRadius.m,
                    style: .continuous
                )
            )
            .duckPrimaryGlow()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .accessibilityHint("Opens Export Album to choose an external drive or Files folder")
    }

    private func addToExportAlbum(_ asset: PHAsset) {
        exportAlbum.add([asset])
        DuckHaptics.selection()
    }

    private var selectedVideoCountLabel: String {
        let count = selectedVideoFiles.count
        guard count > 0 else { return "No videos selected" }
        return "\(count) \(count == 1 ? "video" : "videos") selected"
    }

    private var selectedVideoSizeLabel: String {
        // `formattedBytesStat` renders an empty selection as "0 MB" instead of
        // ByteCountFormatter's "Zero KB".
        let formatted = selectedVideoBytes.formattedBytesStat
        return selectedVideoSizeIsEstimated ? "About \(formatted)" : formatted
    }

    private var exportSelectedTitle: String {
        guard !selectedVideoFiles.isEmpty else {
            return "Export Selected…"
        }
        return "Export \(selectedVideoFiles.count) Selected…"
    }

    private var addSelectedToAlbumTitle: String {
        guard !selectedVideoFiles.isEmpty else {
            return "Add Selected to Export Album"
        }
        if selectedUnqueuedAssets.isEmpty {
            return "Selected Videos Already in Export Album"
        }
        return "Add \(selectedUnqueuedAssets.count) to Export Album"
    }

    private func beginExportSelection() {
        guard !visibleFiles.isEmpty else { return }
        clearExportAlbumConfirmation()
        isSelectingForExport = true
        selectedVideoAssetIDs = LargeVideoExportSelection.reconciledAssetIDs(
            selectedVideoAssetIDs,
            with: visibleFiles
        )
        DuckHaptics.selection()
    }

    private func cancelExportSelection() {
        isSelectingForExport = false
        selectedVideoAssetIDs.removeAll()
        pendingExternalExportFiles.removeAll()
        clearExportAlbumConfirmation()
    }

    /// Leaves selection mode without discarding the selection, so re-entering
    /// with Select restores exactly what the user had picked.
    private func finishExportSelection() {
        isSelectingForExport = false
        clearExportAlbumConfirmation()
    }

    private func clearExportAlbumConfirmation() {
        exportAlbumConfirmationTask?.cancel()
        exportAlbumConfirmationTask = nil
        exportAlbumConfirmation = nil
    }

    private func toggleExportSelection(for file: LargeFile) {
        let assetID = file.photoAsset.localIdentifier
        if selectedVideoAssetIDs.contains(assetID) {
            selectedVideoAssetIDs.remove(assetID)
        } else {
            selectedVideoAssetIDs.insert(assetID)
        }
        DuckHaptics.selection()
    }

    private func toggleSelectAllVisibleVideos() {
        if allVisibleVideosAreSelected {
            selectedVideoAssetIDs.removeAll()
        } else {
            selectedVideoAssetIDs = visibleAssetIDs
        }
        DuckHaptics.selection()
    }

    private func reconcileExportSelection(
        resultsAreAuthoritative: Bool
    ) {
        selectedVideoAssetIDs =
            LargeVideoExportSelection.reconciledAssetIDs(
                selectedVideoAssetIDs,
                with: visibleFiles,
                resultsAreAuthoritative: resultsAreAuthoritative
            )
        if resultsAreAuthoritative, visibleFiles.isEmpty {
            cancelExportSelection()
        }
    }

    private func addSelectedVideosToExportAlbum() {
        let explicitAssets = selectedUnqueuedAssets
        guard !explicitAssets.isEmpty else { return }
        exportAlbum.add(explicitAssets)
        DuckHaptics.success()
        // Saving for later must not discard the selection or navigate away.
        // Confirm in place and let the user keep reviewing.
        let count = explicitAssets.count
        exportAlbumConfirmationTask?.cancel()
        exportAlbumConfirmation =
            "Saved \(count) \(count == 1 ? "video" : "videos") to Export Album. Nothing was moved or deleted."
        exportAlbumConfirmationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            exportAlbumConfirmation = nil
            exportAlbumConfirmationTask = nil
        }
    }

    private func beginExternalExport() {
        let explicitFiles = selectedVideoFiles
        guard !explicitFiles.isEmpty, !isExportingSelection else { return }
        clearExportAlbumConfirmation()
        pendingExternalExportFiles = explicitFiles
        showExternalFolderPicker = true
    }

    @MainActor
    private func exportSelectedVideos(
        _ explicitFiles: [LargeFile],
        to directoryURL: URL
    ) async {
        let explicitAssets = explicitFiles.map(\.photoAsset)
        guard !explicitAssets.isEmpty, !isExportingSelection else {
            return
        }
        guard let exportSessionToken =
                ExternalPhotoExportSessionGate.shared.acquire() else {
            exportError =
                "Another export is already running. Return to it and wait for it to finish or cancel it."
            return
        }

        isExportingSelection = true
        exportError = nil
        completedExportMessage = nil
        selectedExportProgressStore.reset()
        // Let SwiftUI replace the large review controls with the lightweight
        // progress card before ActivityKit and PhotoKit preparation begins.
        await Task.yield()
        UIApplication.shared.isIdleTimerDisabled = true
        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "PhotoDuck Selected Video Export"
        ) {
            Task { @MainActor in
                await selectedExportLiveActivity.markPaused()
            }
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        // See HomeView: the service's total is resource-based, so seed zero
        // and let the first progress update supply the real figure.
        selectedExportLiveActivity.start(
            destinationName: directoryURL.lastPathComponent,
            totalFileCount: 0
        )
        defer {
            ExternalPhotoExportSessionGate.shared.release(
                exportSessionToken
            )
            isExportingSelection = false
            selectedExportProgressStore.reset()
            selectedExportTask = nil
            pendingExternalExportFiles.removeAll()
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }

        do {
            let result = try await ExternalPhotoExportService().export(
                assets: explicitAssets,
                to: directoryURL,
                onProgress: { progress in
                    Task { @MainActor in
                        selectedExportProgressStore.update(progress)
                        await selectedExportLiveActivity.update(
                            with: progress
                        )
                    }
                }
            )
            let remainingAssetIDs = Set(
                explicitAssets.map(\.localIdentifier)
            ).subtracting(result.exportedAssetIDs)
            if result.wasCancelled {
                completedExportTitle = "Export Stopped"
            } else if result.failedAssetCount > 0 {
                completedExportTitle = "Export Complete with Issues"
            } else {
                completedExportTitle = "Export Complete"
            }
            let firstFailure = result.failures.first.map { failure in
                let itemName = failure.filename ?? "Video"
                let additionalFailureCount = result.failures.count - 1
                return " \(itemName): \(failure.message)"
                    + (
                        additionalFailureCount > 0
                            ? " (+\(additionalFailureCount) more)"
                            : ""
                    )
            } ?? ""
            completedExportMessage =
                "Verified \(result.assetCount) of \(result.requestedAssetCount) videos"
                + " (\(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))) "
                + "in \(result.directoryURL.lastPathComponent). "
                + (
                    remainingAssetIDs.isEmpty
                        ? "The originals remain in Photos."
                        : (
                            remainingAssetIDs.count == 1
                                ? "1 unfinished video remains selected so you can retry it."
                                : "\(remainingAssetIDs.count) unfinished videos remain selected so you can retry them."
                        )
                )
                + firstFailure
            let activityPhase:
                PhotoDuckExportActivityAttributes.ContentState.Phase =
                    result.wasCancelled
                        ? .cancelled
                        : (
                            result.failures.isEmpty
                                ? .finished
                                : .completedWithFailures
                        )
            await selectedExportLiveActivity.end(
                phase: activityPhase,
                completedFileCount: result.processedFileCount,
                totalFileCount: result.totalPlannedFileCount
            )
            if result.assetCount > 0 {
                DuckHaptics.success()
            }
            if remainingAssetIDs.isEmpty {
                cancelExportSelection()
            } else {
                selectedVideoAssetIDs = remainingAssetIDs
                isSelectingForExport = true
            }
        } catch is CancellationError {
            completedExportTitle = "Export Cancelled"
            completedExportMessage =
                "Verified videos remain on the drive. No originals were deleted."
            await selectedExportLiveActivity.end(
                phase: .cancelled,
                completedFileCount:
                    selectedExportProgressStore.progress?
                        .completedFileCount ?? 0,
                totalFileCount:
                    selectedExportProgressStore.progress?
                        .totalFileCount ?? 0
            )
        } catch {
            exportError = error.localizedDescription
            await selectedExportLiveActivity.end(
                phase: .failed,
                completedFileCount:
                    selectedExportProgressStore.progress?
                        .completedFileCount ?? 0,
                totalFileCount:
                    selectedExportProgressStore.progress?
                        .totalFileCount ?? 0
            )
        }
    }

    private func refreshVideos() {
        guard scanState != .scanning, let onRefresh else { return }
        Task { await onRefresh() }
    }

    private func requestDeletion(of file: LargeFile) {
        guard !pendingPhotoFileIDs.contains(file.id) else { return }
        deletionError = nil
        pendingPhotoFileIDs.insert(file.id)
        Task { await deletePhotoLibraryFile(file, asset: file.photoAsset) }
    }

    private func deletePhotoLibraryFile(_ file: LargeFile, asset: PHAsset) async {
        do {
            // Large-video review is already an explicit, single-item action.
            // Present Photos' confirmation immediately instead of inserting
            // the app-wide ten-second deferred undo window first.
            try await deletionManager.deleteImmediately(assets: [asset])
            hiddenFileIDs.insert(file.id)
            pendingPhotoFileIDs.remove(file.id)
            onAssetDeleted?(asset.localIdentifier)
        } catch {
            pendingPhotoFileIDs.remove(file.id)
            guard !FileDeletionErrorPolicy.isBenignCancellation(error) else { return }
            deletionError = error.localizedDescription
        }
    }

    private func restoreUndonePhotoLibraryFiles() {
        let undoneAssetIDs = deletionManager.lastUndoneAssetIDs
        guard !undoneAssetIDs.isEmpty else { return }

        let fileIDsToRestore = files.reduce(into: Set<UUID>()) { result, file in
            guard undoneAssetIDs.contains(file.photoAsset.localIdentifier) else {
                return
            }
            result.insert(file.id)
        }
        hiddenFileIDs.subtract(fileIDsToRestore)
        pendingPhotoFileIDs.subtract(fileIDsToRestore)
    }
}

// MARK: - File Row

private struct FileRow: View {
    let file: LargeFile
    let purchaseManager: PurchaseManager
    let isQueuedForExport: Bool
    let isSelectingForExport: Bool
    let isSelectedForExport: Bool
    let isDeleting: Bool
    let onPlay: () -> Void
    let onToggleExportSelection: () -> Void
    let onAddToExport: () -> Void
    let onDelete: () -> Void
    let onCompress: () -> Void

    private var isVideo: Bool {
        file.photoAsset.mediaType == .video
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if isSelectingForExport {
                    Button(action: onToggleExportSelection) {
                        Image(
                            systemName: isSelectedForExport
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.duckTitle)
                        .foregroundStyle(
                            isSelectedForExport
                                ? Color.accentPrimary
                                : Color.textSecondary
                        )
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isSelectedForExport
                            ? "Deselect \(file.displayName)"
                            : "Select \(file.displayName)"
                    )
                }

                LargeVideoThumbnail(
                    asset: file.photoAsset,
                    layout: .list,
                    displayName: file.displayName,
                    isSelectingForExport: isSelectingForExport,
                    isSelectedForExport: isSelectedForExport,
                    onPlay: onPlay,
                    onToggleExportSelection: onToggleExportSelection
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(file.displayName)
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)

                    fileSizeView

                    HStack(spacing: 6) {
                        typeBadge
                        if let date = file.creationDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.duckLabel)
                                .foregroundStyle(Color.decorPink)
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            if isSelectingForExport {
                Button(action: onToggleExportSelection) {
                    Label(
                        isSelectedForExport ? "Selected" : "Select Video",
                        systemImage: isSelectedForExport
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(
                        isSelectedForExport
                            ? Color.white
                            : Color.accentPrimary
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        isSelectedForExport
                            ? Color.accentPrimary
                            : Color.accentPrimary.opacity(0.1),
                        in: RoundedRectangle(
                            cornerRadius: DuckRadius.s,
                            style: .continuous
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityValue(
                    isSelectedForExport ? "Selected" : "Not selected"
                )
            } else {
                HStack(spacing: 8) {
                    Button(action: onAddToExport) {
                        Label(
                            isQueuedForExport ? "Added" : "Add to Album",
                            systemImage: isQueuedForExport
                                ? "checkmark.circle.fill"
                                : "externaldrive.badge.plus"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .font(.duckLabel.weight(.semibold))
                        .foregroundStyle(
                            isQueuedForExport ? Color.success : Color.white
                        )
                        .padding(.horizontal, 8)
                        .background(
                            isQueuedForExport
                                ? Color.success.opacity(0.12)
                                : Color.accentPrimary,
                            in: Capsule()
                        )
                    }
                    .disabled(isQueuedForExport || isDeleting)
                    .accessibilityLabel(
                        isQueuedForExport
                            ? "Added to Export Album"
                            : "Add to Export Album"
                    )
                    .accessibilityHint(
                        isQueuedForExport
                            ? "This video is already in Export Album"
                            : "Adds this video to Export Album without deleting it"
                    )

                    if isVideo {
                        Button(action: onCompress) {
                            HStack(spacing: 4) {
                                Text("Compress")
                                if !purchaseManager.isPurchased {
                                    Image(systemName: "lock.fill")
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .font(.duckLabel.weight(.semibold))
                            .foregroundStyle(Color.accentPrimary)
                            .padding(.horizontal, 8)
                            .background(
                                Color.accentPrimary.opacity(0.1),
                                in: Capsule()
                            )
                        }
                        .disabled(isDeleting)
                    }

                    Button(action: onDelete) {
                        Group {
                            if isDeleting {
                                ProgressView()
                                    .tint(Color.danger)
                            } else {
                                Text("Delete")
                            }
                        }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .font(.duckLabel.weight(.semibold))
                            .foregroundStyle(Color.danger)
                            .padding(.horizontal, 8)
                            .background(Color.danger.opacity(0.10), in: Capsule())
                    }
                    .disabled(isDeleting)
                    .accessibilityLabel(
                        isDeleting
                            ? "Waiting for Photos deletion confirmation"
                            : "Delete video"
                    )
                }
            }
        }
    }

    private var fileSizeView: some View {
        let formatted = splitSize(file.byteSize)
        return HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(file.byteSizeIsEstimated ? "~\(formatted.number)" : formatted.number)
                .font(.duckBody(20, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(Color.accentPrimary)
            Text(formatted.unit)
                .font(.duckCaption.weight(.medium))
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func splitSize(_ bytes: Int64) -> (number: String, unit: String) {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1 {
            return (String(format: "%.1f", gb), "GB")
        } else {
            return (String(format: "%.0f", mb), "MB")
        }
    }

    private var typeBadge: some View {
        Text(isVideo ? "Video" : "File")
            .font(.duckLabel)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isVideo ? Color.warning.opacity(0.15) : Color.accentPrimary.opacity(0.15))
            .foregroundStyle(isVideo ? Color.warning : Color.accentPrimary)
            .clipShape(Capsule())
    }
}

// MARK: - Thumbnail Review

private struct LargeVideoGridCard: View {
    let file: LargeFile
    let purchaseManager: PurchaseManager
    let isQueuedForExport: Bool
    let isSelectingForExport: Bool
    let isSelectedForExport: Bool
    let isDeleting: Bool
    let onPlay: () -> Void
    let onToggleExportSelection: () -> Void
    let onAddToExport: () -> Void
    let onDelete: () -> Void
    let onCompress: () -> Void

    var body: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 8) {
                LargeVideoThumbnail(
                    asset: file.photoAsset,
                    layout: .thumbnails,
                    displayName: file.displayName,
                    isSelectingForExport: isSelectingForExport,
                    isSelectedForExport: isSelectedForExport,
                    onPlay: onPlay,
                    onToggleExportSelection: onToggleExportSelection
                )

                Text(file.displayName)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(file.formattedSize)
                        .font(.duckLabel.weight(.semibold))
                        .foregroundStyle(Color.accentPrimary)
                    Spacer(minLength: 2)
                    if let date = file.creationDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.duckMicro)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                }

                if isSelectingForExport {
                    Button(action: onToggleExportSelection) {
                        Label(
                            isSelectedForExport ? "Selected" : "Select",
                            systemImage: isSelectedForExport
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(
                            isSelectedForExport
                                ? Color.white
                                : Color.accentPrimary
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            isSelectedForExport
                                ? Color.accentPrimary
                                : Color.accentPrimary.opacity(0.1),
                            in: RoundedRectangle(
                                cornerRadius: DuckRadius.s,
                                style: .continuous
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isSelectedForExport
                            ? "Deselect \(file.displayName)"
                            : "Select \(file.displayName)"
                    )
                    .accessibilityValue(
                        isSelectedForExport ? "Selected" : "Not selected"
                    )
                } else {
                    HStack(spacing: 4) {
                        compactAction(
                            systemImage: isQueuedForExport
                                ? "checkmark.circle.fill"
                                : "externaldrive.badge.plus",
                            color:
                                isQueuedForExport
                                    ? .success
                                    : .accentPrimary,
                            accessibilityLabel: isQueuedForExport
                                ? "Added to Export Album"
                                : "Add to Export Album",
                            isDisabled: isQueuedForExport || isDeleting,
                            action: onAddToExport
                        )
                        compactAction(
                            systemImage: purchaseManager.isPurchased
                                ? "arrow.triangle.2.circlepath"
                                : "lock.fill",
                            color: .accentPrimary,
                            accessibilityLabel: purchaseManager.isPurchased
                                ? "Compress video"
                                : "Compress video, requires PhotoDuck unlock",
                            isDisabled: isDeleting,
                            action: onCompress
                        )
                        compactAction(
                            systemImage: "trash",
                            color: .danger,
                            accessibilityLabel: isDeleting
                                ? "Waiting for Photos deletion confirmation"
                                : "Delete video",
                            isDisabled: isDeleting,
                            // Same in-flight treatment as the list row.
                            isInProgress: isDeleting,
                            action: onDelete
                        )
                    }
                }
            }
            .padding(10)
        }
        .overlay {
            // Match DuckCard's own corner radius so the ring cannot clip the
            // card corners.
            RoundedRectangle(cornerRadius: DuckRadius.l, style: .continuous)
                .stroke(
                    isSelectingForExport && isSelectedForExport
                        ? Color.accentPrimary
                        : Color.clear,
                    lineWidth: 3
                )
        }
    }

    private func compactAction(
        systemImage: String,
        color: Color,
        accessibilityLabel: String,
        isDisabled: Bool,
        isInProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isInProgress {
                    ProgressView()
                        .tint(color)
                } else {
                    Image(systemName: systemImage)
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(color)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                color.opacity(0.1),
                in: RoundedRectangle(
                    cornerRadius: DuckRadius.s,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct LargeVideoThumbnail: View {
    let asset: PHAsset
    let layout: LargeVideoReviewLayout
    let displayName: String
    let isSelectingForExport: Bool
    let isSelectedForExport: Bool
    let onPlay: () -> Void
    let onToggleExportSelection: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var localThumbnailUnavailable = false

    var body: some View {
        // In selection mode the biggest target on the row must toggle
        // selection; playback stays reachable outside selection mode.
        Button(action: isSelectingForExport ? onToggleExportSelection : onPlay) {
            ZStack {
                Color.warning.opacity(0.14)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    VStack(spacing: 5) {
                        Image(
                            systemName: localThumbnailUnavailable
                                ? "icloud.and.arrow.down"
                                : "video.fill"
                        )
                        .font(.duckTitle)
                        if localThumbnailUnavailable {
                            Text("Play from iCloud")
                                .font(.duckMicro.weight(.semibold))
                        }
                    }
                    .foregroundStyle(Color.warning)
                }

                if isSelectingForExport {
                    Color.berryBlack.opacity(isSelectedForExport ? 0.28 : 0.12)

                    Image(
                        systemName: isSelectedForExport
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(layout == .list ? .duckTitle : .duckDisplay)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        Color.white,
                        isSelectedForExport
                            ? Color.accentPrimary
                            : Color.black.opacity(0.48)
                    )
                    .shadow(radius: 3)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(layout == .list ? .duckTitle : .duckDisplay)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.48))
                        .shadow(radius: 3)
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(durationLabel)
                            .font(.duckMicro.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: Capsule())
                    }
                }
                .padding(6)
            }
            .frame(
                width: layout == .list ? 120 : nil,
                height: layout == .list ? 120 : nil
            )
            .frame(maxWidth: layout == .thumbnails ? .infinity : nil)
            .aspectRatio(layout == .thumbnails ? 1 : nil, contentMode: .fit)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DuckRadius.s,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelectingForExport
                ? (
                    isSelectedForExport
                        ? "Deselect \(displayName)"
                        : "Select \(displayName)"
                )
                : "Play video, \(durationLabel)"
        )
        .accessibilityValue(
            isSelectingForExport
                ? (isSelectedForExport ? "Selected" : "Not selected")
                : ""
        )
        .accessibilityAddTraits(
            isSelectingForExport && isSelectedForExport ? .isSelected : []
        )
        .accessibilityHint(
            isSelectingForExport
                ? "Adds or removes this video from the export selection"
                : (
                    localThumbnailUnavailable
                        ? "Downloads the video from iCloud if needed"
                        : "Opens the video player"
                )
        )
        .task(id: thumbnailTaskID) {
            image = await PhotoImageRepository.shared.image(
                for: asset,
                targetSize: targetPixelSize,
                contentMode: .aspectFill,
                qualityIntent: .thumbnail,
                allowNetworkAccess: false
            )
            localThumbnailUnavailable = image == nil
        }
    }

    private var thumbnailTaskID: String {
        "\(asset.localIdentifier)-\(layout)-\(displayScale)"
    }

    private var targetPixelSize: CGSize {
        let points: CGFloat = layout == .list ? 120 : 240
        return CGSize(
            width: points * displayScale,
            height: points * displayScale
        )
    }

    private var durationLabel: String {
        let seconds = max(Int(asset.duration.rounded()), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

// MARK: - Video Player

private struct LargeVideoPlayerView: View {
    let file: LargeFile

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var loadingProgress: Double?
    @State private var errorMessage: String?
    @State private var loadAttempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else if let errorMessage {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.duckDisplay)
                            .foregroundStyle(Color.warning)
                        Text("Video couldn’t load")
                            .font(.duckHeading)
                            .foregroundStyle(.white)
                        Text(errorMessage)
                            .font(.duckCaption)
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            self.errorMessage = nil
                            loadAttempt += 1
                        }
                        .font(.duckButton)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(LinearGradient.duckPrimaryCTA, in: Capsule(style: .continuous))
                    }
                    .padding(24)
                } else {
                    VStack(spacing: 12) {
                        if let loadingProgress {
                            ProgressView(value: loadingProgress)
                                .frame(maxWidth: 220)
                                .tint(.white)
                            Text("Loading from iCloud · \(Int(loadingProgress * 100))%")
                                .font(.duckCaption)
                                .foregroundStyle(.white.opacity(0.8))
                        } else {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Loading video…")
                                .font(.duckCaption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
            }
            .navigationTitle(file.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: "\(file.photoAsset.localIdentifier)-\(loadAttempt)") {
            await loadPlayer()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    @MainActor
    private func loadPlayer() async {
        guard player == nil else { return }
        errorMessage = nil
        loadingProgress = nil
        do {
            let item = try await requestPlayableItem(
                for: file.photoAsset
            ) { progress in
                loadingProgress = progress
            }
            try Task.checkCancellation()
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            loadingProgress = nil
            newPlayer.play()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            loadingProgress = nil
        }
    }

    private func requestPlayableItem(
        for asset: PHAsset,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AVPlayerItem {
        do {
            let avAsset = try await requestAVAsset(
                for: asset,
                progress: progress
            )
            try Task.checkCancellation()
            guard try await avAsset.load(.isPlayable) else {
                throw VideoPlaybackLoadingError.notPlayable
            }
            return AVPlayerItem(asset: avAsset)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Some Photos providers expose only a prepared player item rather
            // than a directly playable AVAsset. Keep that route as a fallback.
            let item = try await requestPlayerItem(
                for: asset,
                progress: progress
            )
            try Task.checkCancellation()
            guard try await item.asset.load(.isPlayable) else {
                throw VideoPlaybackLoadingError.notPlayable
            }
            return item
        }
    }

    private func requestAVAsset(
        for asset: PHAsset,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AVAsset {
        let manager = PHImageManager.default()
        let state = VideoPlaybackAssetRequestState()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard state.install(continuation: continuation) else { return }

                let options = PHVideoRequestOptions()
                options.version = .current
                // Playback should begin with the best immediately available
                // representation; forcing highQualityFormat can require a
                // complete multi-gigabyte iCloud download before playing.
                options.deliveryMode = .automatic
                options.isNetworkAccessAllowed = true
                options.progressHandler = { value, _, _, _ in
                    Task { @MainActor in
                        progress(min(max(value, 0), 1))
                    }
                }

                let requestID = manager.requestAVAsset(
                    forVideo: asset,
                    options: options
                ) { avAsset, _, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        state.complete(.failure(error))
                    } else if (info?[PHImageCancelledKey] as? Bool) == true {
                        state.complete(.failure(CancellationError()))
                    } else if let avAsset {
                        state.complete(.success(avAsset))
                    } else {
                        state.complete(
                            .failure(VideoPlaybackLoadingError.unavailable)
                        )
                    }
                }
                state.setRequestID(requestID, manager: manager)
            }
        } onCancel: {
            state.cancel(manager: manager)
        }

        guard let asset = state.asset else {
            throw VideoPlaybackLoadingError.unavailable
        }
        return asset
    }

    private func requestPlayerItem(
        for asset: PHAsset,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AVPlayerItem {
        let manager = PHImageManager.default()
        let state = VideoPlayerItemRequestState()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard state.install(continuation: continuation) else { return }

                let options = PHVideoRequestOptions()
                options.version = .current
                options.deliveryMode = .automatic
                options.isNetworkAccessAllowed = true
                options.progressHandler = { value, _, _, _ in
                    Task { @MainActor in
                        progress(min(max(value, 0), 1))
                    }
                }

                let requestID = manager.requestPlayerItem(
                    forVideo: asset,
                    options: options
                ) { item, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        state.complete(.failure(error))
                    } else if (info?[PHImageCancelledKey] as? Bool) == true {
                        state.complete(.failure(CancellationError()))
                    } else if let item {
                        state.complete(.success(item))
                    } else {
                        state.complete(.failure(VideoPlaybackLoadingError.unavailable))
                    }
                }
                state.setRequestID(requestID, manager: manager)
            }
        } onCancel: {
            state.cancel(manager: manager)
        }

        guard let item = state.item else {
            throw VideoPlaybackLoadingError.unavailable
        }
        return item
    }
}

private enum VideoPlaybackLoadingError: Error, LocalizedError {
    case unavailable
    case notPlayable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "PhotoDuck couldn’t load this video from Photos or iCloud."
        case .notPlayable:
            return "Photos returned this video, but iOS could not play its current version."
        }
    }
}

private final class VideoPlaybackAssetRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID = PHInvalidImageRequestID
    private var isFinished = false
    private var isCancelled = false
    private var storedAsset: AVAsset?

    var asset: AVAsset? {
        lock.lock()
        defer { lock.unlock() }
        return storedAsset
    }

    func install(continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ requestID: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            manager.cancelImageRequest(requestID)
        }
    }

    func complete(_ result: Result<AVAsset, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        if case .success(let asset) = result {
            storedAsset = asset
        }
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func cancel(manager: PHImageManager) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isCancelled = true
        isFinished = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class VideoPlayerItemRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID = PHInvalidImageRequestID
    private var isFinished = false
    private var isCancelled = false
    private var storedItem: AVPlayerItem?

    var item: AVPlayerItem? {
        lock.lock()
        defer { lock.unlock() }
        return storedItem
    }

    func install(continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ requestID: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            manager.cancelImageRequest(requestID)
        }
    }

    func complete(_ result: Result<AVPlayerItem, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        if case .success(let item) = result {
            storedItem = item
        }
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func cancel(manager: PHImageManager) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isCancelled = true
        isFinished = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
        }
        continuation?.resume(throwing: CancellationError())
    }
}
