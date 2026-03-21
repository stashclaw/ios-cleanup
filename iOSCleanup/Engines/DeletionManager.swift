import Foundation
import Photos
import SwiftUI

@MainActor
final class DeletionManager: ObservableObject {
    @Published var toastVisible: Bool = false
    @Published var toastFreedBytes: Int64 = 0
    @Published private(set) var toastID = UUID()
    @Published private(set) var lastCommittedToastID: UUID?
    @Published var isDeleting: Bool = false
    @Published var deletionProgress: Double = 0
    @Published private(set) var bulkTotalCount: Int = 0
    @Published private(set) var bulkProcessedCount: Int = 0
    @Published private(set) var bulkTotalBytes: Int64 = 0
    @Published private(set) var bulkProcessedBytes: Int64 = 0
    @Published var totalBytesFreed: Int64 = 0
    @Published var totalItemsFreed: Int = 0
    @Published var toastFreedCount: Int = 0

    private var pendingAssets: [PHAsset] = []
    private var pendingFreedBytes: Int64 = 0
    private var lastDeletedIdentifiers: [String] = []
    private var commitTask: Task<Void, Never>?

    // MARK: - Public API

    func keepBest(from group: PhotoGroup) async throws {
        let toDelete = try PhotoDeletionGuardrails.deleteAssets(in: group)
        try await scheduleDelete(assets: toDelete)
    }

    func delete(assets: [PHAsset]) async throws {
        try await scheduleDelete(assets: assets)
    }

    func bulkDelete(groups: [PhotoGroup]) async throws {
        let assets = try groups.flatMap { try PhotoDeletionGuardrails.deleteAssets(in: $0) }
        try await bulkDelete(assets: assets)
    }

    func undoLast() {
        let restoredIdentifiers = lastDeletedIdentifiers
        commitTask?.cancel()
        commitTask = nil
        pendingAssets = []
        pendingFreedBytes = 0
        lastDeletedIdentifiers = []
        toastFreedCount = 0
        toastVisible = false
        if !restoredIdentifiers.isEmpty {
            Task {
                await PhotoFeedbackStore.shared.recordUndoRestore(
                    assetIDs: restoredIdentifiers,
                    note: "Undo last deletion"
                )
            }
        }
    }

    // MARK: - Bulk delete (no undo toast — scale too large)

    func bulkDelete(assets: [PHAsset]) async throws {
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

        var processed = 0
        var processedBytes: Int64 = 0
        let batchSize = 50
        for batchStart in stride(from: 0, to: assets.count, by: batchSize) {
            let end = min(batchStart + batchSize, assets.count)
            let batchAssets = Array(assets[batchStart..<end])
            let batchBytes = estimatedBytes(for: batchAssets)
            try await performDelete(assets: batchAssets)
            processed += batchAssets.count
            processedBytes += batchBytes
            deletionProgress = Double(processed) / Double(total)
            bulkProcessedCount = processed
            bulkProcessedBytes = min(processedBytes, bulkTotalBytes)
            totalBytesFreed += batchBytes
            totalItemsFreed += batchAssets.count
        }
    }

    // MARK: - Private

    private func scheduleDelete(assets: [PHAsset]) async throws {
        commitTask?.cancel()

        pendingAssets = assets
        pendingFreedBytes = estimatedBytes(for: assets)
        toastFreedCount = assets.count
        toastID = UUID()
        lastCommittedToastID = nil

        toastFreedBytes = pendingFreedBytes
        toastVisible = true

        let scheduledToastID = toastID
        commitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            do {
                try await self.performDelete(assets: self.pendingAssets)
                self.lastDeletedIdentifiers = self.pendingAssets.map(\.localIdentifier)
                self.lastCommittedToastID = scheduledToastID
                self.totalBytesFreed += self.pendingFreedBytes
                self.totalItemsFreed += self.pendingAssets.count
                self.pendingAssets = []
                self.pendingFreedBytes = 0
            } catch {
                // Deletion failed — toast already dismissed by now
            }
            self.toastVisible = false
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
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func estimatedBytes(for assets: [PHAsset]) -> Int64 {
        assets.reduce(into: Int64(0)) { acc, a in
            acc += a.estimatedFileSize
        }
    }
}
