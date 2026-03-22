import Foundation
import Photos

actor PhotoFeedbackStore {
    static let shared = PhotoFeedbackStore()

    static let schemaVersion = 1
    static let maxStoredRawEvents = 1_000
    static let maxExportRows = 5_000

    private let fileURL: URL
    private let profileStore: PhotoPreferenceProfileStore
    private var events: [PhotoReviewFeedbackEvent] = []
    private var dedupeKeys = Set<String>()
    private var isLoaded = false

    init(directoryURL: URL? = nil, profileStore: PhotoPreferenceProfileStore = .shared) {
        let baseURL = directoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("PhotoDuck/learning", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("photo-feedback-events.json")
        self.profileStore = profileStore
    }

    func append(_ event: PhotoReviewFeedbackEvent) async -> Bool {
        await loadIfNeeded()
        guard appendToRawHistory(event) else { return false }
        let pruned = pruneIfNeeded()
        if pruned {
            // Keep the on-disk archive bounded immediately so retention is real,
            // not just an in-memory promise.
        }
        save()
        await profileStore.rebuild(from: events)
        return true
    }

    func append(_ newEvents: [PhotoReviewFeedbackEvent]) async {
        await loadIfNeeded()
        var appendedAny = false
        for event in newEvents {
            appendedAny = appendToRawHistory(event) || appendedAny
        }
        guard appendedAny else { return }
        let pruned = pruneIfNeeded()
        if pruned {
            // Keep the on-disk archive bounded immediately so retention is real,
            // not just an in-memory promise.
        }
        save()
        await profileStore.rebuild(from: events)
    }

    func recordSimilarGroupDecision(
        group: PhotoGroup,
        source: PhotoReviewFeedbackSource = .similarGroupReview,
        kind: PhotoReviewDecisionKind,
        stage: PhotoReviewDecisionStage = .committed,
        selectedKeeperID: String? = nil,
        deletedAssetIDs: [String] = [],
        keptAssetIDs: [String] = [],
        skipped: Bool = false,
        recommendationAccepted: Bool? = nil,
        note: String? = nil
    ) async -> Bool {
        let keeperID = selectedKeeperID ?? group.keeperAssetID
        let finalKeeperID = keeperID
        let resolvedDeletedIDs = dedupeIDs(deletedAssetIDs.isEmpty ? group.deleteCandidateIDs : deletedAssetIDs)
        let resolvedKeptIDs = dedupeIDs(keptAssetIDs.isEmpty ? keeperID.map { [$0] } ?? [] : keptAssetIDs)
        let acceptance = recommendationAccepted ?? Self.recommendationAccepted(
            kind: kind,
            suggestedKeeperID: group.keeperAssetID,
            finalKeeperID: keeperID,
            suggestedDeleteAssetIDs: group.deleteCandidateIDs,
            deletedAssetIDs: resolvedDeletedIDs
        )
        let assets = makeAssetSnapshots(
            group: group,
            kind: kind,
            selectedKeeperID: keeperID,
            deletedAssetIDs: resolvedDeletedIDs,
            keptAssetIDs: resolvedKeptIDs,
            skipped: skipped
        )
        let event = PhotoReviewFeedbackEvent(
            source: source,
            kind: kind,
            stage: stage,
            dedupeKey: makeDedupKey(
                source: source,
                kind: kind,
                groupID: group.id,
                selectedKeeperID: finalKeeperID,
                deletedAssetIDs: resolvedDeletedIDs,
                keptAssetIDs: resolvedKeptIDs,
                stage: stage
            ),
            groupID: group.id,
            groupType: group.groupType,
            bucket: group.reason.feedbackBucket,
            confidence: group.groupConfidence.feedbackConfidence,
            suggestedAction: group.recommendedAction?.feedbackSuggestedAction ?? group.groupConfidence.feedbackSuggestedAction,
            suggestedKeeperAssetID: group.keeperAssetID,
            finalKeeperAssetID: finalKeeperID,
            deletedAssetIDs: resolvedDeletedIDs,
            keptAssetIDs: resolvedKeptIDs,
            skipped: skipped,
            recommendationAccepted: acceptance,
            assets: assets,
            note: note
        )
        return await append(event)
    }

    func recordSwipeDecision(
        asset: PHAsset,
        groupID: UUID? = nil,
        kind: PhotoReviewDecisionKind,
        stage: PhotoReviewDecisionStage = .committed,
        note: String? = nil
    ) async -> Bool {
        let role: PhotoReviewAssetRole
        switch kind {
        case .swipeKeep:
            role = .kept
        case .swipeDelete:
            role = .deleted
        default:
            role = .candidate
        }

        let assetSnapshot = asset.photoReviewFeedbackAsset(role: role)
        let event = PhotoReviewFeedbackEvent(
            source: .swipeMode,
            kind: kind,
            stage: stage,
            dedupeKey: makeDedupKey(
                source: .swipeMode,
                kind: kind,
                groupID: groupID,
                selectedKeeperID: assetSnapshot.localIdentifier,
                deletedAssetIDs: kind == .swipeDelete ? [assetSnapshot.localIdentifier] : [],
                keptAssetIDs: kind == .swipeKeep ? [assetSnapshot.localIdentifier] : [],
                stage: stage
            ),
            groupID: groupID,
            deletedAssetIDs: kind == .swipeDelete ? [assetSnapshot.localIdentifier] : [],
            keptAssetIDs: kind == .swipeKeep ? [assetSnapshot.localIdentifier] : [],
            recommendationAccepted: nil,
            assets: [assetSnapshot],
            note: note
        )
        return await append(event)
    }

    func recordUndoRestore(
        assetIDs: [String],
        note: String? = nil
    ) async -> Bool {
        guard !assetIDs.isEmpty else { return false }
        let uniqueIDs = dedupeIDs(assetIDs)
        let assets = uniqueIDs.map { id in
            PhotoReviewFeedbackAsset(
                localIdentifier: id,
                role: .restored,
                flags: ["undoRestore"]
            )
        }
        let event = PhotoReviewFeedbackEvent(
            source: .deleteManager,
            kind: .restoreUndo,
            stage: .committed,
            dedupeKey: makeDedupKey(
                source: .deleteManager,
                kind: .restoreUndo,
                groupID: nil,
                selectedKeeperID: nil,
                deletedAssetIDs: uniqueIDs,
                keptAssetIDs: [],
                stage: .committed
            ),
            deletedAssetIDs: [],
            keptAssetIDs: uniqueIDs,
            recommendationAccepted: nil,
            assets: assets,
            note: note
        )
        return await append(event)
    }

    func loadAllEvents() async -> [PhotoReviewFeedbackEvent] {
        await loadIfNeeded()
        return events
    }

    func recentEvents(limit: Int = 50) async -> [PhotoReviewFeedbackEvent] {
        await loadIfNeeded()
        return Array(events.suffix(limit).reversed())
    }

    func exportRows(limit: Int = maxExportRows) async -> [PhotoTrainingExportRow] {
        await loadIfNeeded()
        return PhotoTrainingExampleBuilder.makeRows(from: events.suffix(limit))
    }

    func approximateDiskFootprintBytes() async -> Int64 {
        await loadIfNeeded()
        guard let data = try? JSONEncoder.photoDuck.encode(PhotoFeedbackArchive(schemaVersion: Self.schemaVersion, savedAt: Date(), events: events)) else {
            return 0
        }
        return Int64(data.count)
    }

    func feedbackSummaryLines() async -> [String] {
        let profile = await profileStore.snapshot()
        return profile.debugSummaryLines() + ["rawEvents=\(events.count)"]
    }

    func clear() async {
        await loadIfNeeded()
        events.removeAll()
        dedupeKeys.removeAll()
        save()
        await profileStore.rebuild(from: [])
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let archive = try? JSONDecoder.photoDuck.decode(PhotoFeedbackArchive.self, from: data) else { return }
        guard archive.schemaVersion == Self.schemaVersion else { return }
        events = archive.events
        dedupeKeys = Set(archive.events.map(\.dedupeKey).filter { !$0.isEmpty })
        if pruneIfNeeded() {
            save()
        }
        await profileStore.rebuild(from: events)
    }

    private func pruneIfNeeded() -> Bool {
        guard events.count > Self.maxStoredRawEvents else { return false }
        let overflow = events.count - Self.maxStoredRawEvents
        guard overflow > 0 else { return false }
        events.removeFirst(overflow)
        dedupeKeys = Set(events.map(\.dedupeKey).filter { !$0.isEmpty })
        return true
    }

    private func appendToRawHistory(_ event: PhotoReviewFeedbackEvent) -> Bool {
        let key = event.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, dedupeKeys.contains(key) {
            return false
        }

        events.append(event)
        if !key.isEmpty {
            dedupeKeys.insert(key)
        }
        return true
    }

    private func save() {
        let archive = PhotoFeedbackArchive(
            schemaVersion: Self.schemaVersion,
            savedAt: Date(),
            events: events
        )
        guard let data = try? JSONEncoder.photoDuck.encode(archive) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func makeAssetSnapshots(
        group: PhotoGroup,
        kind: PhotoReviewDecisionKind,
        selectedKeeperID: String?,
        deletedAssetIDs: [String],
        keptAssetIDs: [String],
        skipped: Bool
    ) -> [PhotoReviewFeedbackAsset] {
        let deletedSet = Set(deletedAssetIDs)
        let keptSet = Set(keptAssetIDs)
        let sortedAssets = group.assets.sorted { $0.localIdentifier < $1.localIdentifier }

        return sortedAssets.map { asset in
            let candidate = group.candidates.first(where: { $0.photoId == asset.localIdentifier })
            let isSuggestedKeeper = asset.localIdentifier == group.keeperAssetID
            let isFinalKeeper = asset.localIdentifier == selectedKeeperID
            let role: PhotoReviewAssetRole
            if skipped {
                role = .skipped
            } else if deletedSet.contains(asset.localIdentifier) {
                role = .deleted
            } else if keptSet.contains(asset.localIdentifier) || isFinalKeeper {
                role = isFinalKeeper ? .finalKeeper : .kept
            } else if isSuggestedKeeper {
                role = kind == .keeperOverride ? .suggestedKeeper : .finalKeeper
            } else {
                role = .candidate
            }

            return asset.photoReviewFeedbackAsset(
                role: role,
                keeperAssetID: selectedKeeperID,
                similarityToKeeper: nil,
                rankingScore: candidate?.bestShotScore,
                flags: candidate?.issueFlags.map(\.title) ?? []
            )
        }
    }

    private func makeDedupKey(
        source: PhotoReviewFeedbackSource,
        kind: PhotoReviewDecisionKind,
        groupID: UUID?,
        selectedKeeperID: String?,
        deletedAssetIDs: [String],
        keptAssetIDs: [String],
        stage: PhotoReviewDecisionStage
    ) -> String {
        let deleted = dedupeIDs(deletedAssetIDs).joined(separator: ",")
        let kept = dedupeIDs(keptAssetIDs).joined(separator: ",")
        return [
            source.rawValue,
            kind.rawValue,
            stage.rawValue,
            groupID?.uuidString ?? "none",
            selectedKeeperID ?? "none",
            deleted.isEmpty ? "none" : deleted,
            kept.isEmpty ? "none" : kept
        ].joined(separator: "|")
    }

    private func dedupeIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func recommendationAccepted(
        kind: PhotoReviewDecisionKind,
        suggestedKeeperID: String?,
        finalKeeperID: String?,
        suggestedDeleteAssetIDs: [String],
        deletedAssetIDs: [String]
    ) -> Bool? {
        switch kind {
        case .keepBest, .keeperOverride:
            guard let finalKeeperID else { return nil }
            return finalKeeperID == suggestedKeeperID
        case .deleteSelected:
            guard !suggestedDeleteAssetIDs.isEmpty else { return nil }
            let selected = Set(deletedAssetIDs)
            return !selected.isEmpty && selected.isSubset(of: Set(suggestedDeleteAssetIDs))
        case .skipGroup:
            return nil
        case .swipeKeep, .swipeDelete, .restoreUndo, .editPreferenceSignal:
            return nil
        }
    }
}

private struct PhotoFeedbackArchive: Codable {
    let schemaVersion: Int
    let savedAt: Date
    let events: [PhotoReviewFeedbackEvent]
}

private extension PhotoGroup.SimilarityReason {
    var feedbackBucket: SimilarityBucket {
        switch self {
        case .nearDuplicate:
            return .nearDuplicate
        case .visuallySimilar:
            return .visuallySimilar
        case .burstShot:
            return .burstShot
        }
    }
}

private extension SimilarGroupConfidence {
    var feedbackConfidence: GroupConfidence {
        switch self {
        case .high:
            return .high
        case .medium:
            return .medium
        case .low:
            return .low
        }
    }
}

private extension SimilarRecommendedAction {
    var feedbackSuggestedAction: SuggestedAction {
        switch self {
        case .keepBestTrashRest:
            return .suggestDeleteOthers
        case .reviewManually:
            return .reviewTogetherOnly
        case .keepAll:
            return .doNotSuggestDeletion
        }
    }
}

private extension SimilarGroupConfidence {
    var feedbackSuggestedAction: SuggestedAction {
        switch self {
        case .high:
            return .suggestDeleteOthers
        case .medium, .low:
            return .reviewTogetherOnly
        }
    }
}

private extension JSONEncoder {
    static var photoDuck: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var photoDuck: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
