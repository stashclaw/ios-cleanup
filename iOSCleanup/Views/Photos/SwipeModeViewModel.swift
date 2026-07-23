import Foundation
import Photos
import SwiftUI

@MainActor
final class SwipeModeViewModel: ObservableObject {

    // MARK: - Queue entry

    enum QueueEntry: Identifiable {
        case asset(PHAsset, groupID: UUID)
        case monthHeader(String)

        var id: String {
            switch self {
            case .asset(let a, _): return a.localIdentifier
            case .monthHeader(let s): return "header-\(s)"
            }
        }
    }

    enum SwipeDecision {
        case keep
        case delete
    }

    // MARK: - State

    @Published var queue: [QueueEntry] = []
    @Published var currentIndex: Int = 0
    @Published var isComplete = false
    @Published var deleteError: String?
    @Published private(set) var transitionDecision: SwipeDecision?

    private let allGroups: [PhotoGroup]
    private var transitionTask: Task<Void, Never>?
    private var swipeHistory: [(asset: PHAsset, groupID: UUID, decision: SwipeDecision)] = []
    private(set) var totalReviewableCount: Int = 0
    private var keptAssets: [PHAsset] = []
    private(set) var toDeleteAssets: [PHAsset] = []
    private var toDeleteGroupIDsByAssetID: [String: UUID] = [:]
    private var fileSizeByAssetID: [String: Int64] = [:]
    private var pendingDeleteByteCount: Int64 = 0
    private var optimisticallyCommittedAssets: [
        String: (asset: PHAsset, groupID: UUID, bytes: Int64)
    ] = [:]
    private(set) var deletedCount = 0
    private(set) var deletedBytes: Int64 = 0

    var keptCount: Int { keptAssets.count }
    var duckedCount: Int { toDeleteAssets.count + deletedCount }
    var reviewedCount: Int { keptCount + duckedCount }
    var remainingCount: Int { max(totalReviewableCount - reviewedCount, 0) }
    var isTransitioning: Bool { transitionDecision != nil }
    var hasPendingDeletes: Bool { !toDeleteAssets.isEmpty }
    var canUndoLastSwipe: Bool { !swipeHistory.isEmpty && !isTransitioning }
    var pendingDeleteAssets: [PHAsset] { toDeleteAssets }

    var pendingDeleteBytes: Int64 { pendingDeleteByteCount }

    init(groups: [PhotoGroup]) {
        allGroups = groups
        buildQueue(from: groups)
    }

    var current: QueueEntry? {
        guard currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var progress: Double {
        guard totalReviewableCount > 0 else { return 1 }
        return Double(reviewedCount) / Double(totalReviewableCount)
    }

    // MARK: - Actions

    /// Swipe right = keep
    func keep() {
        beginTransition(.keep)
    }

    /// Swipe left = delete (individual decisions are free)
    func delete() {
        beginTransition(.delete)
    }

    private func beginTransition(_ decision: SwipeDecision) {
        guard transitionDecision == nil, case .asset = current else { return }
        transitionDecision = decision
        transitionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.commit(decision)
        }
    }

    private func commit(_ decision: SwipeDecision) {
        guard case .asset(let asset, let groupID) = current else {
            finishTransition()
            return
        }

        switch decision {
        case .keep:
            DuckHaptics.impact(.light)
            keptAssets.append(asset)
            Task {
                await PhotoFeedbackStore.shared.recordSwipeDecision(
                    asset: asset,
                    groupID: groupID,
                    kind: .swipeKeep,
                    stage: .committed,
                    note: "Duck Mode keep"
                )
            }

        case .delete:
            DuckHaptics.impact(.medium)
            toDeleteAssets.append(asset)
            toDeleteGroupIDsByAssetID[asset.localIdentifier] = groupID
            pendingDeleteByteCount += fileSizeByAssetID[asset.localIdentifier] ?? 0
        }

        swipeHistory.append((asset, groupID, decision))
        advance()
        finishTransition()
    }

    private func finishTransition() {
        transitionDecision = nil
        transitionTask = nil
    }

    func resetQueue() {
        transitionTask?.cancel()
        transitionTask = nil
        transitionDecision = nil
        keptAssets = []
        toDeleteAssets = []
        pendingDeleteByteCount = 0
        deletedCount = 0
        deletedBytes = 0
        deleteError = nil
        isComplete = false
        toDeleteGroupIDsByAssetID.removeAll()
        swipeHistory.removeAll()
        buildQueue(from: allGroups)
    }

    func undoLastSwipe() {
        guard transitionDecision == nil, let last = swipeHistory.popLast() else {
            return
        }

        switch last.decision {
        case .keep:
            keptAssets.removeAll { $0.localIdentifier == last.asset.localIdentifier }
        case .delete:
            toDeleteAssets.removeAll { $0.localIdentifier == last.asset.localIdentifier }
            toDeleteGroupIDsByAssetID.removeValue(forKey: last.asset.localIdentifier)
            pendingDeleteByteCount = max(
                pendingDeleteByteCount - (fileSizeByAssetID[last.asset.localIdentifier] ?? 0),
                0
            )
        }

        if let index = queue.firstIndex(where: { entry in
            guard case .asset(let asset, _) = entry else { return false }
            return asset.localIdentifier == last.asset.localIdentifier
        }) {
            currentIndex = index
            isComplete = false
        }
        deleteError = nil
        DuckHaptics.rigid()
    }

    private func advance() {
        currentIndex += 1
        // Skip headers automatically
        while currentIndex < queue.count, case .monthHeader = queue[currentIndex] {
            currentIndex += 1
        }
        if currentIndex >= queue.count {
            isComplete = true
        }
    }

    // MARK: - Manual swipe commit (free)

    func commitDeletes(using deletionManager: DeletionManager) async {
        guard !toDeleteAssets.isEmpty else { return }
        do {
            let assets = toDeleteAssets
            let bytes = pendingDeleteBytes
            try await deletionManager.delete(assets: assets)
            deletedCount += toDeleteAssets.count
            deletedBytes += bytes
            for asset in toDeleteAssets {
                let groupID = toDeleteGroupIDsByAssetID[asset.localIdentifier]
                if let groupID {
                    optimisticallyCommittedAssets[asset.localIdentifier] = (
                        asset,
                        groupID,
                        fileSizeByAssetID[asset.localIdentifier] ?? 0
                    )
                }
                Task {
                    await PhotoFeedbackStore.shared.recordSwipeDecision(
                        asset: asset,
                        groupID: groupID,
                        kind: .swipeDelete,
                        stage: .committed,
                        note: "Duck Mode delete committed"
                    )
                }
            }
            toDeleteAssets.removeAll()
            pendingDeleteByteCount = 0
            toDeleteGroupIDsByAssetID.removeAll()
            // Once PhotoKit owns the pending operation, the global deletion toast
            // is the authoritative undo path.
            swipeHistory.removeAll()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    func restoreUndoneAssets(_ assetIDs: Set<String>) {
        let restored = assetIDs.compactMap { assetID -> (PHAsset, UUID, Int64)? in
            guard let committed = optimisticallyCommittedAssets.removeValue(forKey: assetID) else {
                return nil
            }
            return (committed.asset, committed.groupID, committed.bytes)
        }
        .sorted {
            let lhsDate = $0.0.creationDate ?? .distantPast
            let rhsDate = $1.0.creationDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return $0.0.localIdentifier < $1.0.localIdentifier
        }
        guard !restored.isEmpty else { return }

        deletedCount = max(deletedCount - restored.count, 0)
        deletedBytes = max(deletedBytes - restored.reduce(0) { $0 + $1.2 }, 0)

        let queuedFutureAssetIDs = Set(queue.dropFirst(currentIndex).compactMap { entry -> String? in
            guard case .asset(let asset, _) = entry else { return nil }
            return asset.localIdentifier
        })
        var appendedAsset = false
        for (asset, groupID, _) in restored where !queuedFutureAssetIDs.contains(asset.localIdentifier) {
            queue.append(.asset(asset, groupID: groupID))
            appendedAsset = true
        }

        if appendedAsset {
            isComplete = false
        }
        deleteError = nil
    }

    func fileSize(for assetID: String) -> Int64? {
        fileSizeByAssetID[assetID]
    }

    // MARK: - Queue building

    private func buildQueue(from groups: [PhotoGroup]) {
        let keeperIDs = Set(groups.compactMap(\.keeperAssetID))
        var queuedAssetIDs = Set<String>()
        let orderedGroups = groups.sorted { lhs, rhs in
            let lhsPriority = lhs.preferenceQueuePriority ?? 0
            let rhsPriority = rhs.preferenceQueuePriority ?? 0
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }

            let lhsDate = lhs.captureDateRange?.start ?? lhs.assets.compactMap(\.creationDate).min() ?? .distantPast
            let rhsDate = rhs.captureDateRange?.start ?? rhs.assets.compactMap(\.creationDate).min() ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }

        let queuedAssets = orderedGroups.flatMap { group -> [(PHAsset, UUID)] in
            guard group.isAutoCleanEligible else { return [] }
            let deleteIDs = group.deleteCandidateIDs
            guard !deleteIDs.isEmpty else { return [] }

            let assetMap = Dictionary(uniqueKeysWithValues: group.assets.map { ($0.localIdentifier, $0) })
            var result: [(PHAsset, UUID)] = []
            result.reserveCapacity(deleteIDs.count)
            for id in deleteIDs {
                guard !keeperIDs.contains(id), queuedAssetIDs.insert(id).inserted else { continue }
                guard let asset = assetMap[id] else { continue }
                result.append((asset, group.id))
            }
            return result
        }

        let assets = queuedAssets.sorted {
            let lhsDate = $0.0.creationDate ?? .distantPast
            let rhsDate = $1.0.creationDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return $0.0.localIdentifier < $1.0.localIdentifier
        }
        totalReviewableCount = assets.count
        fileSizeByAssetID = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.0.localIdentifier, $0.0.estimatedFileSize)
        })

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"

        var lastMonth = ""
        var entries: [QueueEntry] = []
        for (asset, groupID) in assets {
            let month = formatter.string(from: asset.creationDate ?? Date())
            if month != lastMonth {
                entries.append(.monthHeader(month))
                lastMonth = month
            }
            entries.append(.asset(asset, groupID: groupID))
        }

        queue = entries
        currentIndex = 0
        while currentIndex < queue.count, case .monthHeader = queue[currentIndex] {
            currentIndex += 1
        }
        isComplete = currentIndex >= queue.count
    }
}
