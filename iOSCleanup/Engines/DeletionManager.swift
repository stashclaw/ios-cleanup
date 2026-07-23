import Foundation
import Photos
import SwiftUI

enum DeletionManagerError: Error, LocalizedError {
    case deletionAlreadyPending
    case photoLibraryRejectedDeletion

    var errorDescription: String? {
        switch self {
        case .deletionAlreadyPending:
            return "Another deletion is waiting for confirmation. Undo it or let it finish first."
        case .photoLibraryRejectedDeletion:
            return "The photo library did not complete the deletion."
        }
    }
}

struct CleanupStats: Codable, Equatable, Sendable {
    var lifetimeBytesFreed: Int64 = 0
    var lifetimeItemsFreed: Int = 0
}

final class CleanupStatsStore {
    private static let key = "photoduck.cleanup-stats.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CleanupStats {
        guard let data = defaults.data(forKey: Self.key),
              let stats = try? JSONDecoder().decode(CleanupStats.self, from: data) else {
            return CleanupStats()
        }
        return stats
    }

    @discardableResult
    func recordConfirmedDeletion(bytes: Int64, itemCount: Int) -> CleanupStats {
        var stats = load()
        stats.lifetimeBytesFreed = Self.addingWithoutOverflow(
            stats.lifetimeBytesFreed,
            max(bytes, 0)
        )
        stats.lifetimeItemsFreed = Self.addingWithoutOverflow(
            stats.lifetimeItemsFreed,
            max(itemCount, 0)
        )
        if let data = try? JSONEncoder().encode(stats) {
            defaults.set(data, forKey: Self.key)
        }
        return stats
    }

    private static func addingWithoutOverflow<T: FixedWidthInteger>(
        _ lhs: T,
        _ rhs: T
    ) -> T {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        return overflowed ? .max : result
    }
}

@MainActor
final class DeletionManager: ObservableObject {
    @Published var toastVisible: Bool = false
    @Published var toastFreedBytes: Int64 = 0
    @Published private(set) var toastID = UUID()
    @Published private(set) var toastDeadline = Date()
    @Published private(set) var lastCommittedToastID: UUID?
    @Published private(set) var lastDeletionError: String?
    @Published private(set) var undoEventID = UUID()
    @Published private(set) var lastUndoneAssetIDs: Set<String> = []
    @Published private(set) var lastFailedAssetIDs: Set<String> = []
    @Published var isDeleting: Bool = false
    @Published var deletionProgress: Double = 0
    @Published private(set) var bulkTotalCount: Int = 0
    @Published private(set) var bulkProcessedCount: Int = 0
    @Published private(set) var bulkTotalBytes: Int64 = 0
    @Published private(set) var bulkProcessedBytes: Int64 = 0
    @Published var totalBytesFreed: Int64 = 0
    @Published var totalItemsFreed: Int = 0
    @Published private(set) var lifetimeBytesFreed: Int64
    @Published private(set) var lifetimeItemsFreed: Int
    @Published var toastFreedCount: Int = 0

    private var pendingAssets: [PHAsset] = []
    private var pendingFreedBytes: Int64 = 0
    private var pendingCommitStarted = false
    private var commitTask: Task<Void, Never>?
    private let undoWindowSeconds: TimeInterval = 10
    private let cleanupStatsStore: CleanupStatsStore

    init(cleanupStatsStore: CleanupStatsStore = CleanupStatsStore()) {
        self.cleanupStatsStore = cleanupStatsStore
        let stats = cleanupStatsStore.load()
        lifetimeBytesFreed = stats.lifetimeBytesFreed
        lifetimeItemsFreed = stats.lifetimeItemsFreed
    }

    var hasPendingDeletion: Bool {
        commitTask != nil || isDeleting
    }

    // MARK: - Public API

    func keepBest(from group: PhotoGroup) async throws {
        let toDelete = try PhotoDeletionGuardrails.deleteAssets(in: group)
        try await scheduleDelete(assets: toDelete)
    }

    func keepBest(from groups: [PhotoGroup]) async throws {
        try PhotoDeletionGuardrails.validate(groups: groups)
        let assets = uniqueAssets(from: groups.flatMap(\.deleteCandidateAssets))
        try await scheduleDelete(assets: assets)
    }

    func delete(assets: [PHAsset]) async throws {
        try await scheduleDelete(assets: assets)
    }

    func bulkDelete(groups: [PhotoGroup]) async throws {
        try PhotoDeletionGuardrails.validate(groups: groups)
        let assets = uniqueAssets(from: groups.flatMap(\.deleteCandidateAssets))
        try await bulkDelete(assets: assets)
    }

    func undoLast() {
        guard !pendingCommitStarted else { return }
        let undoneIDs = pendingAssets.map(\.localIdentifier)
        lastUndoneAssetIDs = Set(undoneIDs)
        undoEventID = UUID()
        commitTask?.cancel()
        clearPendingDeletion(for: toastID)
        DuckHaptics.rigid()
        Task {
            await PhotoFeedbackStore.shared.recordUndoRestore(
                assetIDs: undoneIDs,
                note: "Deferred PhotoKit deletion cancelled during undo window"
            )
        }
    }

    func dismissLastError() {
        lastDeletionError = nil
    }

    // MARK: - Bulk delete (no undo toast — scale too large)

    func bulkDelete(assets: [PHAsset]) async throws {
        if pendingCommitStarted, let commitTask {
            await commitTask.value
        } else if commitTask != nil {
            try await commitPendingDeletionNow()
        }
        guard !isDeleting else {
            throw DeletionManagerError.deletionAlreadyPending
        }
        isDeleting = true
        deletionProgress = 0
        bulkTotalCount = assets.count
        bulkProcessedCount = 0
        bulkTotalBytes = estimatedBytes(for: assets)
        bulkProcessedBytes = 0
        defer {
            isDeleting = false
        }

        let total = assets.count
        guard total > 0 else { return }
        let identifiers = assets.map(\.localIdentifier)
        guard Set(identifiers).count == identifiers.count else {
            throw PhotoDeletionGuardrailError.duplicateDeleteCandidateIDs
        }

        // Keep the user-confirmed plan atomic. Batched PhotoKit requests can leave
        // a partially deleted queue that is unsafe to retry after a later failure.
        try await performDelete(assets: assets)
        deletionProgress = 1
        bulkProcessedCount = total
        bulkProcessedBytes = bulkTotalBytes
        totalBytesFreed += bulkTotalBytes
        totalItemsFreed += total
        recordConfirmedDeletion(bytes: bulkTotalBytes, itemCount: total)
        DuckHaptics.success()
    }

    // MARK: - Private

    private func scheduleDelete(assets: [PHAsset]) async throws {
        if pendingCommitStarted, let commitTask {
            await commitTask.value
        }
        guard !isDeleting else {
            throw DeletionManagerError.deletionAlreadyPending
        }
        guard !assets.isEmpty else {
            throw PhotoDeletionGuardrailError.emptyDeleteCandidateList
        }
        let identifiers = assets.map(\.localIdentifier)
        guard Set(identifiers).count == identifiers.count else {
            throw PhotoDeletionGuardrailError.duplicateDeleteCandidateIDs
        }

        pendingAssets = uniqueAssets(from: pendingAssets + assets)
        pendingFreedBytes = estimatedBytes(for: pendingAssets)
        pendingCommitStarted = false
        toastFreedCount = pendingAssets.count
        toastID = UUID()
        toastDeadline = Date().addingTimeInterval(undoWindowSeconds)
        lastCommittedToastID = nil
        lastDeletionError = nil
        lastFailedAssetIDs = []

        toastFreedBytes = pendingFreedBytes
        toastVisible = true

        let scheduledToastID = toastID
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                try Task.checkCancellation()
                guard let self, self.toastID == scheduledToastID else { return }

                self.pendingCommitStarted = true
                let scheduledAssets = self.pendingAssets
                let scheduledBytes = self.pendingFreedBytes
                try await self.performDelete(assets: scheduledAssets)

                self.lastCommittedToastID = scheduledToastID
                self.totalBytesFreed += scheduledBytes
                self.totalItemsFreed += scheduledAssets.count
                self.recordConfirmedDeletion(
                    bytes: scheduledBytes,
                    itemCount: scheduledAssets.count
                )
                DuckHaptics.success()
                self.clearPendingDeletion(for: scheduledToastID)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.toastID == scheduledToastID else { return }
                self.lastFailedAssetIDs = Set(self.pendingAssets.map(\.localIdentifier))
                self.lastDeletionError = error.localizedDescription
                self.clearPendingDeletion(for: scheduledToastID)
            }
        }
        // Scheduling is intentionally nonblocking. Callers can update their local
        // UI optimistically while the user retains one coalesced undo window.
    }

    private func commitPendingDeletionNow() async throws {
        guard !pendingAssets.isEmpty else { return }

        let scheduledToastID = toastID
        let scheduledAssets = pendingAssets
        let scheduledBytes = pendingFreedBytes
        commitTask?.cancel()
        commitTask = nil
        pendingCommitStarted = true

        do {
            try await performDelete(assets: scheduledAssets)
            lastCommittedToastID = scheduledToastID
            totalBytesFreed += scheduledBytes
            totalItemsFreed += scheduledAssets.count
            recordConfirmedDeletion(
                bytes: scheduledBytes,
                itemCount: scheduledAssets.count
            )
            DuckHaptics.success()
            clearPendingDeletion(for: scheduledToastID)
        } catch {
            lastFailedAssetIDs = Set(scheduledAssets.map(\.localIdentifier))
            clearPendingDeletion(for: scheduledToastID)
            throw error
        }
    }

    private func performDelete(assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if !success {
                    continuation.resume(throwing: DeletionManagerError.photoLibraryRejectedDeletion)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func clearPendingDeletion(for scheduledToastID: UUID) {
        guard toastID == scheduledToastID else { return }
        commitTask = nil
        pendingAssets = []
        pendingFreedBytes = 0
        pendingCommitStarted = false
        toastFreedCount = 0
        toastVisible = false
    }

    private func uniqueAssets(from assets: [PHAsset]) -> [PHAsset] {
        var seen = Set<String>()
        return assets.filter { seen.insert($0.localIdentifier).inserted }
    }

    private func estimatedBytes(for assets: [PHAsset]) -> Int64 {
        assets.reduce(into: Int64(0)) { acc, a in
            acc += a.estimatedFileSize
        }
    }

    private func recordConfirmedDeletion(bytes: Int64, itemCount: Int) {
        let stats = cleanupStatsStore.recordConfirmedDeletion(
            bytes: bytes,
            itemCount: itemCount
        )
        lifetimeBytesFreed = stats.lifetimeBytesFreed
        lifetimeItemsFreed = stats.lifetimeItemsFreed
    }
}
