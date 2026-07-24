import Foundation
import Photos
import SwiftUI

enum DeletionManagerError: Error, LocalizedError {
    case photoLibraryRejectedDeletion

    var errorDescription: String? {
        switch self {
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
    @Published var totalBytesFreed: Int64 = 0
    @Published var totalItemsFreed: Int = 0
    @Published private(set) var lifetimeBytesFreed: Int64
    @Published private(set) var lifetimeItemsFreed: Int
    @Published var toastFreedCount: Int = 0

    private var pendingAssets: [PHAsset] = []
    private var pendingFreedBytes: Int64 = 0
    private var pendingCommitStarted = false
    /// Keepers protected by any deletion already waiting in the undo window.
    /// A later request that coalesces into the same batch must not delete them.
    private var pendingProtectedKeeperIDs: Set<String> = []
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
        commitTask != nil
    }

    // MARK: - Public API

    func keepBest(from group: PhotoGroup) async throws {
        let toDelete = try PhotoDeletionGuardrails.deleteAssets(in: group)
        try await scheduleDelete(
            assets: toDelete,
            protectedKeeperIDs: Set([group.keeperAssetID].compactMap { $0 })
        )
    }

    func keepBest(from groups: [PhotoGroup]) async throws {
        try PhotoDeletionGuardrails.validate(groups: groups)
        let assets = uniqueAssets(from: groups.flatMap(\.deleteCandidateAssets))
        try await scheduleDelete(
            assets: assets,
            protectedKeeperIDs: Set(groups.compactMap(\.keeperAssetID))
        )
    }

    func delete(assets: [PHAsset]) async throws {
        try await scheduleDelete(assets: assets)
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

    // MARK: - Private

    private func scheduleDelete(
        assets: [PHAsset],
        protectedKeeperIDs: Set<String> = []
    ) async throws {
        if pendingCommitStarted, let commitTask {
            await commitTask.value
        }
        guard !assets.isEmpty else {
            throw PhotoDeletionGuardrailError.emptyDeleteCandidateList
        }
        let identifiers = assets.map(\.localIdentifier)
        guard Set(identifiers).count == identifiers.count else {
            throw PhotoDeletionGuardrailError.duplicateDeleteCandidateIDs
        }

        // Coalescing merges this request into any batch still inside the undo
        // window, so the keeper/delete conflict check must span the merged
        // batch, not just the current call. Doing the same requests as one call
        // would have failed cross-group validation; the merged batch must too.
        let mergedDeleteIDs = Set(pendingAssets.map(\.localIdentifier))
            .union(identifiers)
        let mergedKeeperIDs = pendingProtectedKeeperIDs.union(protectedKeeperIDs)
        guard mergedKeeperIDs.isDisjoint(with: mergedDeleteIDs) else {
            throw PhotoDeletionGuardrailError.crossGroupKeeperConflict
        }

        pendingAssets = uniqueAssets(from: pendingAssets + assets)
        pendingProtectedKeeperIDs = mergedKeeperIDs
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
        commitTask = Task { [weak self, undoWindowSeconds] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(undoWindowSeconds * 1_000_000_000)
                )
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
        pendingProtectedKeeperIDs = []
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
