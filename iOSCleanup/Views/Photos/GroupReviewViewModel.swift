import Foundation
import Photos
import SwiftUI
@preconcurrency import Vision

@MainActor
final class GroupReviewViewModel: ObservableObject {

    static let cacheKey     = "GroupReview_markedIDs"
    static let completedKey = "GroupReview_completedGroups"
    static let skippedKey   = "GroupReview_skippedGroups"

    // MARK: - Published state

    @Published var queue: [PhotoGroup]
    @Published var currentIndex: Int = 0
    /// All non-skipped groups passed at init time — used by startFresh() to restore the full queue.
    private let allGroups: [PhotoGroup]

    /// Group keys that have been finalized (queued for delete). Survives clearCache() so groups
    /// stay hidden after commitDeletes() clears markedIDs but before the library updates.
    @Published private(set) var completedGroupKeys: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: completedKey) ?? [])
    }()

    /// Group keys the user explicitly skipped. Reactive so PhotoResultsView auto-updates.
    @Published private(set) var skippedGroupKeys: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: skippedKey) ?? [])
    }()

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
        let skipped   = Set(UserDefaults.standard.stringArray(forKey: Self.skippedKey)   ?? [])
        let completed = Set(UserDefaults.standard.stringArray(forKey: Self.completedKey) ?? [])
        let cached    = Set(UserDefaults.standard.stringArray(forKey: Self.cacheKey)     ?? [])

        // All non-skipped groups — kept for startFresh() so completed groups can be shown again.
        let nonSkipped = groups.filter { !skipped.contains(Self.groupKey(for: $0)) }
        self.allGroups = nonSkipped

        // Active queue: exclude completed groups too (they are permanently done).
        self.queue = nonSkipped.filter { !completed.contains(Self.groupKey(for: $0)) }
        self._markedIDs = Published(initialValue: cached)

        // Advance past any groups whose assets are already queued (crash-recovery resume).
        var startIndex = 0
        while startIndex < self.queue.count {
            guard self.queue[startIndex].assets.contains(where: { cached.contains($0.localIdentifier) }) else { break }
            startIndex += 1
        }
        self.currentIndex = startIndex

        if self.queue.indices.contains(startIndex) {
            setup(group: self.queue[startIndex])
        }
        Task { await rerankCurrentGroup() }
    }

    /// Stable key for a group: sorted asset IDs joined by comma.
    static func groupKey(for group: PhotoGroup) -> String {
        group.assets.map(\.localIdentifier).sorted().joined(separator: ",")
    }

    /// Removes a group from the skipped list so it reappears in the review queue.
    static func unskipGroup(_ group: PhotoGroup) {
        var skipped = Set(UserDefaults.standard.stringArray(forKey: skippedKey) ?? [])
        skipped.remove(groupKey(for: group))
        UserDefaults.standard.set(Array(skipped), forKey: skippedKey)
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
        if let group = currentGroup { persistCompleted(group) }
        markedIDs.formUnion(pendingMarked)
        step()
        Task { await rerankCurrentGroup() }
    }

    /// Skips current group without queuing anything, and persists the skip so it won't reappear.
    func skipGroup() {
        if let group = currentGroup { persistSkip(group) }
        step()
        Task { await rerankCurrentGroup() }
    }

    private func persistSkip(_ group: PhotoGroup) {
        let key = Self.groupKey(for: group)
        skippedGroupKeys.insert(key)
        UserDefaults.standard.set(Array(skippedGroupKeys), forKey: Self.skippedKey)
    }

    /// Removes a group from the skipped list so it reappears in the review queue.
    func unskipGroup(_ group: PhotoGroup) {
        let key = Self.groupKey(for: group)
        skippedGroupKeys.remove(key)
        UserDefaults.standard.set(Array(skippedGroupKeys), forKey: Self.skippedKey)
    }

    func persistCompleted(_ group: PhotoGroup) {
        completedGroupKeys.insert(Self.groupKey(for: group))
        UserDefaults.standard.set(Array(completedGroupKeys), forKey: Self.completedKey)
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

    /// Requests a 224×224 thumbnail for `asset` and returns the flattened
    /// `VNFeaturePrintObservation` as `[Float]`, or `nil` if extraction fails.
    /// Uses the same ImageNet input size as `SimilarityEngine`.
    private func extractFeatureVector(for asset: PHAsset) async -> [Float]? {
        // Request a 224×224 thumbnail from the photo library.
        let image: UIImage? = await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = false
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 224, height: 224),
                contentMode: .aspectFill,
                options: opts
            ) { img, info in
                guard !resumed else { return }
                // Skip the first (degraded/low-res preview) delivery.
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                resumed = true
                continuation.resume(returning: img)
            }
        }

        guard let image, let cgImage = image.cgImage else { return nil }

        // Run VNGenerateImageFeaturePrintRequest synchronously on this thread.
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }

        // Copy the raw float data out of the observation.
        let count = observation.elementCount
        var vector = [Float](repeating: 0, count: count)
        observation.data.withUnsafeBytes { ptr in
            if let floatPtr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                for i in 0..<count { vector[i] = floatPtr[i] }
            }
        }
        return vector.isEmpty ? nil : vector
    }

    /// Builds UserDecision records for every group that has marked (queued-for-delete) assets.
    /// Must be called BEFORE PHPhotoLibrary.performChanges — deleted assets cannot be accessed afterwards.
    /// Extracts VNFeaturePrintObservation vectors concurrently (max 4 tasks) for kept + deleted assets.
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

            // All assets whose vectors we need: kept first, then deleted (in deletedIDs order).
            let allAssets: [PHAsset] = [keptAsset] + deletedAssets

            // Extract feature vectors concurrently, capping at 4 parallel tasks to
            // avoid memory pressure from simultaneous large image decompresses.
            var vectorsByID: [String: [Float]] = [:]
            await withTaskGroup(of: (String, [Float]?).self) { taskGroup in
                var inFlight = 0
                var assetIter = allAssets.makeIterator()

                // Seed the first batch.
                while inFlight < 4, let asset = assetIter.next() {
                    let id = asset.localIdentifier
                    taskGroup.addTask { [weak self] in
                        guard let self else { return (id, nil) }
                        let vec = await self.extractFeatureVector(for: asset)
                        return (id, vec)
                    }
                    inFlight += 1
                }

                // Drain results and schedule remaining assets.
                for await (id, vec) in taskGroup {
                    if let vec { vectorsByID[id] = vec }
                    inFlight -= 1
                    if let next = assetIter.next() {
                        let nextID = next.localIdentifier
                        taskGroup.addTask { [weak self] in
                            guard let self else { return (nextID, nil) }
                            let v = await self.extractFeatureVector(for: next)
                            return (nextID, v)
                        }
                        inFlight += 1
                    }
                }
            }

            // Fetch quality data — should be cached from display, so no new Vision work.
            let keptLabels = await PhotoQualityAnalyzer.shared.labels(for: keptAsset)
            let keptScore  = await PhotoQualityAnalyzer.shared.qualityScore(for: keptAsset)

            var deletedLabels: [[String]] = []
            var deletedScores: [Float] = []
            var deletedVectors: [[Float]] = []
            for asset in deletedAssets {
                let labels = await PhotoQualityAnalyzer.shared.labels(for: asset)
                let score  = await PhotoQualityAnalyzer.shared.qualityScore(for: asset)
                deletedLabels.append(labels.map(\.rawValue))
                deletedScores.append(score)
                deletedVectors.append(vectorsByID[asset.localIdentifier] ?? [])
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
                deletedQualityScores: deletedScores,
                featureVector: vectorsByID[keptID],
                // Keep parallel structure with deletedAssetIDs; empty sub-array means extraction failed for that asset.
                deletedFeatureVectors: deletedVectors
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

        // Ensure every group that contributed queued assets is marked completed BEFORE
        // clearCache() wipes markedIDs. This covers queueAll() and any other path that
        // sets markedIDs without going through queueAndAdvance().
        for group in queue {
            if group.assets.contains(where: { markedIDs.contains($0.localIdentifier) }) {
                persistCompleted(group)
            }
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
        }

        NotificationCenter.default.post(
            name: .didFreeBytes, object: nil,
            userInfo: ["bytes": bytes, "count": assets.count]
        )
        clearCache()
    }

    // MARK: - Cache management

    func clearCache() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        markedIDs = []
        // completedGroupKeys intentionally NOT cleared — groups stay hidden until the library
        // updates naturally, or until the user taps "Start Fresh".
    }

    static func clearSkippedGroups() {
        UserDefaults.standard.removeObject(forKey: skippedKey)
    }

    static var skippedGroupCount: Int {
        (UserDefaults.standard.stringArray(forKey: skippedKey) ?? []).count
    }

    func startFresh() {
        clearCache()
        completedGroupKeys = []
        UserDefaults.standard.removeObject(forKey: Self.completedKey)
        queue = allGroups   // restore completed groups so user sees everything again
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
