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

    // MARK: - State

    @Published var queue: [QueueEntry] = []
    @Published var currentIndex: Int = 0
    @Published var isComplete = false
    @Published var deleteError: String?

    private let allGroups: [PhotoGroup]
    private(set) var totalReviewableCount: Int = 0
    private var keptAssets: [PHAsset] = []
    private(set) var toDeleteAssets: [PHAsset] = []
    private var toDeleteGroupIDsByAssetID: [String: UUID] = [:]
    private(set) var deletedCount = 0
    private(set) var deletedBytes: Int64 = 0

    var keptCount: Int { keptAssets.count }
    var duckedCount: Int { toDeleteAssets.count + deletedCount }
    var reviewedCount: Int { keptCount + duckedCount }
    var remainingCount: Int { max(totalReviewableCount - reviewedCount, 0) }

    var pendingDeleteBytes: Int64 {
        toDeleteAssets.reduce(into: Int64(0)) { acc, a in
            acc += a.estimatedFileSize
        }
    }

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
        if case .asset(let asset, _) = current {
            keptAssets.append(asset)
            if case .asset(_, let groupID) = current {
                Task {
                    await PhotoFeedbackStore.shared.recordSwipeDecision(
                        asset: asset,
                        groupID: groupID,
                        kind: .swipeKeep,
                        stage: .committed,
                        note: "Duck Mode keep"
                    )
                }
            }
        }
        advance()
    }

    /// Swipe left = delete (individual deletes are free)
    func delete() {
        if case .asset(let asset, _) = current {
            toDeleteAssets.append(asset)
            if case .asset(_, let groupID) = current {
                toDeleteGroupIDsByAssetID[asset.localIdentifier] = groupID
                Task {
                    await PhotoFeedbackStore.shared.recordSwipeDecision(
                        asset: asset,
                        groupID: groupID,
                        kind: .swipeDelete,
                        stage: .provisional,
                        note: "Duck Mode delete"
                    )
                }
            }
        }
        advance()
    }

    func resetQueue() {
        keptAssets = []
        toDeleteAssets = []
        deletedCount = 0
        deletedBytes = 0
        deleteError = nil
        isComplete = false
        toDeleteGroupIDsByAssetID.removeAll()
        buildQueue(from: allGroups)
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

    // MARK: - Bulk confirm (paid) — commits pending deletes at completion screen

    func commitDeletes() async {
        guard !toDeleteAssets.isEmpty else { return }
        do {
            let assets = toDeleteAssets
            let bytes = pendingDeleteBytes
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
                }) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            deletedCount += toDeleteAssets.count
            deletedBytes += bytes
            for asset in toDeleteAssets {
                let groupID = toDeleteGroupIDsByAssetID[asset.localIdentifier]
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
            toDeleteGroupIDsByAssetID.removeAll()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    // MARK: - Queue building

    private func buildQueue(from groups: [PhotoGroup]) {
        let queuedAssets = groups.flatMap { group -> [(PHAsset, UUID)] in
            let deleteIDs: [String]
            if !group.deleteCandidateIDs.isEmpty {
                deleteIDs = group.deleteCandidateIDs
            } else if let keeperAssetID = group.keeperAssetID {
                deleteIDs = group.assets.map(\.localIdentifier).filter { $0 != keeperAssetID }
            } else {
                deleteIDs = []
            }

            let assetMap = Dictionary(uniqueKeysWithValues: group.assets.map { ($0.localIdentifier, $0) })
            var result: [(PHAsset, UUID)] = []
            result.reserveCapacity(deleteIDs.count)
            for id in deleteIDs {
                guard let asset = assetMap[id] else { continue }
                result.append((asset, group.id))
            }
            return result
        }

        let assets = queuedAssets.sorted {
            ($0.0.creationDate ?? .distantPast) < ($1.0.creationDate ?? .distantPast)
        }
        totalReviewableCount = assets.count

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
    }
}
