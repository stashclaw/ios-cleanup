import Foundation
import Photos
import SwiftUI

@MainActor
final class GroupReviewViewModel: ObservableObject {

    private static let cacheKey = "GroupReview_markedIDs"

    // MARK: - Published state

    @Published var queue: [PhotoGroup]
    @Published var currentIndex: Int = 0

    /// Globally committed marks (persisted, cross-group).
    @Published var markedIDs: Set<String> {
        didSet { persistCache() }
    }

    /// The "keep" photo for the current group — will NOT be deleted.
    @Published var bestIDForCurrentGroup: String? = nil

    /// Photos in the current group pending queue (not yet committed to markedIDs).
    @Published var pendingMarked: Set<String> = []

    @Published var deleteError: String?

    // MARK: - Computed

    var pendingCount: Int { pendingMarked.count }

    var markedGroupCount: Int {
        queue.filter { group in
            group.assets.contains { markedIDs.contains($0.localIdentifier) }
        }.count
    }

    var currentGroup: PhotoGroup? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var progress: Double {
        queue.isEmpty ? 1.0 : Double(currentIndex) / Double(queue.count)
    }

    var isComplete: Bool { currentIndex >= queue.count }

    var hasCachedSession: Bool {
        !(UserDefaults.standard.stringArray(forKey: Self.cacheKey) ?? []).isEmpty
    }

    // MARK: - Init

    init(groups: [PhotoGroup]) {
        self.queue = groups
        let cached = UserDefaults.standard.stringArray(forKey: Self.cacheKey) ?? []
        self._markedIDs = Published(initialValue: Set(cached))
        if let first = groups.first { setup(group: first) }
        Task { await rerankCurrentGroup() }
    }

    // MARK: - Group setup

    private func setup(group: PhotoGroup) {
        bestIDForCurrentGroup = group.assets.first?.localIdentifier
        // Auto-mark every photo except the best for deletion.
        pendingMarked = Set(group.assets.dropFirst().map(\.localIdentifier))
    }

    /// Re-ranks the current group's assets by quality score and updates bestIDForCurrentGroup.
    /// Called after navigation (queueAndAdvance / skipGroup) so the default "best" is the
    /// highest-quality photo, not just assets[0].
    func rerankCurrentGroup() async {
        guard let group = currentGroup, group.assets.count > 1 else { return }

        var scores: [String: Float] = [:]
        await withTaskGroup(of: (String, Float).self) { taskGroup in
            for asset in group.assets {
                taskGroup.addTask {
                    let score = await PhotoQualityAnalyzer.shared.qualityScore(for: asset)
                    return (asset.localIdentifier, score)
                }
            }
            for await (id, score) in taskGroup {
                scores[id] = score
            }
        }

        guard let best = group.assets.max(by: {
            (scores[$0.localIdentifier] ?? 0.5) < (scores[$1.localIdentifier] ?? 0.5)
        }) else { return }

        let bestID = best.localIdentifier
        bestIDForCurrentGroup = bestID
        // Re-auto-mark everything that isn't the new best.
        pendingMarked = Set(group.assets.compactMap {
            $0.localIdentifier == bestID ? nil : $0.localIdentifier
        })
    }

    // MARK: - Per-group actions

    /// Makes `id` the new "best" for the current group; auto-marks all others.
    func selectBest(_ id: String) {
        guard let group = currentGroup else { return }
        bestIDForCurrentGroup = id
        pendingMarked = Set(group.assets.compactMap {
            $0.localIdentifier == id ? nil : $0.localIdentifier
        })
    }

    /// Toggles an individual pending mark. Best photo can also be marked for full-group deletion.
    func togglePendingMark(_ id: String) {
        if pendingMarked.contains(id) {
            pendingMarked.remove(id)
            // If we just un-marked the best, it stays best (no change needed).
        } else {
            pendingMarked.insert(id)
            // If the user marked the current best, clear it — no "best" remains.
            if id == bestIDForCurrentGroup { bestIDForCurrentGroup = nil }
        }
    }

    /// Marks every photo in the current group for deletion and advances.
    func deleteAllAndAdvance() {
        guard let group = currentGroup else { return }
        let allIDs = group.assets.map(\.localIdentifier)
        pendingMarked = Set(allIDs)
        bestIDForCurrentGroup = nil
        queueAndAdvance()
    }

    // MARK: - Navigation

    /// Commits current group's pending marks and moves to next group.
    func queueAndAdvance() {
        markedIDs.formUnion(pendingMarked)
        step()
        Task { await rerankCurrentGroup() }
    }

    /// Skips current group without queuing anything.
    func skipGroup() {
        step()
        Task { await rerankCurrentGroup() }
    }

    private func step() {
        pendingMarked = []
        bestIDForCurrentGroup = nil
        currentIndex += 1
        if let g = currentGroup { setup(group: g) }
    }

    // MARK: - Queue all groups at once

    /// Marks all non-best photos from every group for deletion without stepping through individually.
    func queueAll() {
        for group in queue {
            guard let bestID = group.assets.first?.localIdentifier else { continue }
            let toMark = group.assets.compactMap { $0.localIdentifier == bestID ? nil : $0.localIdentifier }
            markedIDs.formUnion(toMark)
        }
    }

    // MARK: - Training data capture

    /// Builds UserDecision records for every group that has marked (queued-for-delete) assets.
    /// Must be called BEFORE PHPhotoLibrary.performChanges — deleted assets cannot be accessed afterwards.
    func buildDecisions() async -> [UserDecision] {
        var decisions: [UserDecision] = []

        for group in queue {
            // Find which assets in this group are queued for deletion.
            let groupAssetIDs = Set(group.assets.map(\.localIdentifier))
            let groupMarked = markedIDs.intersection(groupAssetIDs)
            guard !groupMarked.isEmpty else { continue }

            // The kept asset is the one in this group NOT queued for deletion.
            // If all are marked (deleteAllAndAdvance), there is no "kept" — skip pairwise record.
            let keptIDs = groupAssetIDs.subtracting(groupMarked)
            guard let keptID = keptIDs.first else { continue }

            // Look up assets by localIdentifier.
            let keptFetch = PHAsset.fetchAssets(withLocalIdentifiers: [keptID], options: nil)
            guard let keptAsset = keptFetch.firstObject else { continue }

            let deletedIDs = Array(groupMarked)
            let deletedFetch = PHAsset.fetchAssets(withLocalIdentifiers: deletedIDs, options: nil)
            var deletedAssets: [PHAsset] = []
            deletedFetch.enumerateObjects { a, _, _ in deletedAssets.append(a) }
            guard !deletedAssets.isEmpty else { continue }

            // Fetch quality data — should be cached from display, so no new Vision work.
            let keptLabels = await PhotoQualityAnalyzer.shared.labels(for: keptAsset)
            let keptScore  = await PhotoQualityAnalyzer.shared.qualityScore(for: keptAsset)

            var deletedLabels: [[String]] = []
            var deletedScores: [Float] = []
            for asset in deletedAssets {
                let labels = await PhotoQualityAnalyzer.shared.labels(for: asset)
                let score  = await PhotoQualityAnalyzer.shared.qualityScore(for: asset)
                deletedLabels.append(labels.map(\.rawValue))
                deletedScores.append(score)
            }

            let reasonString: String
            switch group.reason {
            case .nearDuplicate:   reasonString = "nearDuplicate"
            case .exactDuplicate:  reasonString = "exactDuplicate"
            case .visuallySimilar: reasonString = "visuallySimilar"
            case .burstShot:       reasonString = "burstShot"
            }

            let decision = UserDecision(
                id: UUID(),
                recordedAt: Date(),
                keptAssetID: keptID,
                deletedAssetIDs: deletedIDs,
                groupID: group.id,
                similarityReason: reasonString,
                keptLabels: keptLabels.map(\.rawValue),
                deletedLabels: deletedLabels,
                keptQualityScore: keptScore,
                deletedQualityScores: deletedScores
            )
            decisions.append(decision)
        }

        return decisions
    }

    // MARK: - Bulk delete (single PHPhotoLibrary call)

    func commitDeletes() async throws {
        // Capture training decisions BEFORE deletion — assets won't be accessible afterwards.
        let decisions = await buildDecisions()
        for decision in decisions {
            await UserDecisionStore.shared.record(decision)
        }

        let ids = Array(markedIDs)
        guard !ids.isEmpty else { clearCache(); return }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }
        guard !assets.isEmpty else { clearCache(); return }

        let bytes = assets.reduce(Int64(0)) { sum, a in
            let size = PHAssetResource.assetResources(for: a)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return sum + size
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
        }

        if bytes > 0 {
            NotificationCenter.default.post(
                name: .didFreeBytes, object: nil, userInfo: ["bytes": bytes]
            )
        }
        clearCache()
    }

    // MARK: - Cache management

    func clearCache() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        markedIDs = []
    }

    func startFresh() {
        clearCache()
        currentIndex = 0
        pendingMarked = []
        bestIDForCurrentGroup = nil
        if let first = queue.first { setup(group: first) }
        Task { await rerankCurrentGroup() }
    }

    private func persistCache() {
        if markedIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        } else {
            UserDefaults.standard.set(Array(markedIDs), forKey: Self.cacheKey)
        }
    }
}
