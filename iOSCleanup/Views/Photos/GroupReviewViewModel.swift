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

    // MARK: - Bulk delete (single PHPhotoLibrary call)

    func commitDeletes() async throws {
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
