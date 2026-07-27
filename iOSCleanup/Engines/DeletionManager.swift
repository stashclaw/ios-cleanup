import Foundation
import Photos
import UIKit
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
    private var undoWindowBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
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
        try await keepBestImmediately(from: [group])
    }

    func keepBest(from groups: [PhotoGroup]) async throws {
        try await keepBestImmediately(from: groups)
    }

    /// Photos presents the final destructive confirmation. PhotoDuck does not
    /// add a second ten-second delay before asking the system to delete.
    func keepBestImmediately(from groups: [PhotoGroup]) async throws {
        try PhotoDeletionGuardrails.validate(groups: groups)
        let assets = PhotoAssetIdentity.unique(
            groups.flatMap(\.deleteCandidateAssets)
        )
        guard !assets.isEmpty else {
            throw PhotoDeletionGuardrailError.emptyDeleteCandidateList
        }

        let deleteIDs = Set(assets.map(\.localIdentifier))
        let keeperIDs = Set(groups.compactMap(\.keeperAssetID))
        let pendingDeleteIDs = Set(
            pendingAssets.map(\.localIdentifier)
        )
        guard pendingProtectedKeeperIDs.isDisjoint(with: deleteIDs),
              pendingDeleteIDs.isDisjoint(with: deleteIDs),
              pendingDeleteIDs.isDisjoint(with: keeperIDs) else {
            throw PhotoDeletionGuardrailError.crossGroupKeeperConflict
        }

        let freedBytes = estimatedBytes(for: assets)
        try await performDelete(assets: assets)
        totalBytesFreed += freedBytes
        totalItemsFreed += assets.count
        recordConfirmedDeletion(
            bytes: freedBytes,
            itemCount: assets.count
        )
        DuckHaptics.success()
    }

    func delete(assets: [PHAsset]) async throws {
        try await deleteImmediately(assets: assets)
    }

    /// Presents Photos' system confirmation immediately.
    func deleteImmediately(assets: [PHAsset]) async throws {
        let uniqueAssets = PhotoAssetIdentity.unique(assets)
        guard !uniqueAssets.isEmpty else {
            throw PhotoDeletionGuardrailError.emptyDeleteCandidateList
        }

        // This path skips the undo window, so it must still honour the same
        // cross-batch guardrail: an asset protected as a keeper by a deletion
        // waiting in that window may not be hard-deleted here.
        let identifiers = Set(uniqueAssets.map(\.localIdentifier))
        guard pendingProtectedKeeperIDs.isDisjoint(with: identifiers) else {
            throw PhotoDeletionGuardrailError.crossGroupKeeperConflict
        }
        // An asset already queued in the pending batch would otherwise be
        // deleted twice and counted twice toward lifetime freed bytes.
        let pendingIdentifiers = Set(pendingAssets.map(\.localIdentifier))
        guard pendingIdentifiers.isDisjoint(with: identifiers) else {
            throw PhotoDeletionGuardrailError.duplicateDeleteAcrossGroups
        }

        let freedBytes = estimatedBytes(for: uniqueAssets)
        try await performDelete(assets: uniqueAssets)
        totalBytesFreed += freedBytes
        totalItemsFreed += uniqueAssets.count
        recordConfirmedDeletion(
            bytes: freedBytes,
            itemCount: uniqueAssets.count
        )
        DuckHaptics.success()
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

    /// Declining Photos' system "Delete Photos?" confirmation surfaces as
    /// `PHPhotosError.userCancelled` (3072). That is a deliberate answer, not a
    /// failure, and must never be reported to the user as an error.
    static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain
            && nsError.code == PHPhotosError.Code.userCancelled.rawValue
    }

    /// The undo window is a 10-second sleep. Without a background assertion,
    /// leaving the app cancels it and the deletion the user was already told
    /// was happening silently never occurs. The lease keeps the commit alive;
    /// if iOS reclaims it first, the commit runs immediately instead.
    func beginUndoWindowLease() {
        guard undoWindowBackgroundTaskID == .invalid else { return }
        undoWindowBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "PhotoDuck Undo Window"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.commitPendingDeletionImmediately()
            }
        }
    }

    func endUndoWindowLease() {
        guard undoWindowBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(undoWindowBackgroundTaskID)
        undoWindowBackgroundTaskID = .invalid
    }

    /// Commits without waiting out the rest of the undo window. Used when iOS
    /// is about to suspend the app: honouring the already-reported deletion
    /// beats losing it.
    func commitPendingDeletionImmediately() async {
        guard !pendingCommitStarted, !pendingAssets.isEmpty else {
            endUndoWindowLease()
            return
        }
        commitTask?.cancel()
        commitTask = nil
        pendingCommitStarted = true

        let scheduledToastID = toastID
        let scheduledAssets = pendingAssets
        let scheduledBytes = pendingFreedBytes
        do {
            try await performDelete(assets: scheduledAssets)
            lastCommittedToastID = scheduledToastID
            totalBytesFreed += scheduledBytes
            totalItemsFreed += scheduledAssets.count
            recordConfirmedDeletion(
                bytes: scheduledBytes,
                itemCount: scheduledAssets.count
            )
        } catch {
            let affectedIDs = Set(scheduledAssets.map(\.localIdentifier))
            if Self.isUserCancellation(error) {
                restoreAfterDeclinedDeletion(affectedIDs)
            } else {
                lastFailedAssetIDs = affectedIDs
                lastDeletionError = error.localizedDescription
            }
        }
        clearPendingDeletion(for: scheduledToastID)
        endUndoWindowLease()
    }

    /// Nothing was removed, so every surface that optimistically hid these
    /// assets must restore them — the same reconciliation an undo performs.
    private func restoreAfterDeclinedDeletion(_ assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }
        lastUndoneAssetIDs = assetIDs
        undoEventID = UUID()
    }

    // MARK: - Private

    private func scheduleDelete(
        assets: [PHAsset],
        protectedKeeperIDs: Set<String> = []
    ) async throws {
        if pendingCommitStarted, let commitTask {
            await commitTask.value
        }
        let uniqueRequestedAssets = PhotoAssetIdentity.unique(assets)
        guard !uniqueRequestedAssets.isEmpty else {
            throw PhotoDeletionGuardrailError.emptyDeleteCandidateList
        }
        let identifiers = uniqueRequestedAssets.map(\.localIdentifier)

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

        pendingAssets = PhotoAssetIdentity.unique(
            pendingAssets + uniqueRequestedAssets
        )
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
        beginUndoWindowLease()
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
                let affectedIDs = Set(self.pendingAssets.map(\.localIdentifier))
                if Self.isUserCancellation(error) {
                    // The user declined Photos' confirmation. Restore the
                    // optimistic UI silently instead of alarming them with
                    // "Couldn't remove photos" for a deliberate "no".
                    self.restoreAfterDeclinedDeletion(affectedIDs)
                } else {
                    self.lastFailedAssetIDs = affectedIDs
                    self.lastDeletionError = error.localizedDescription
                }
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
        endUndoWindowLease()
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
