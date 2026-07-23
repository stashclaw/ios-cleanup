import Foundation
import Photos

protocol PhotoFeedbackPersisting: Sendable {
    func persistFeedbackEvents(_ events: [PhotoReviewFeedbackEvent]) async
}

extension PhotoMLBridge: PhotoFeedbackPersisting {}

actor PhotoFeedbackStore {
    static let shared = PhotoFeedbackStore()

    static let schemaVersion = 1
    static let featureSchemaVersion = 2
    static let maxStoredRawEvents = 1_000
    static let maxExportRows = 5_000
    static let flushDelayNanoseconds: UInt64 = 2_000_000_000

    private let fileURL: URL
    private let journalURL: URL
    private let profileStore: PhotoPreferenceProfileStore
    private let persistence: any PhotoFeedbackPersisting
    private let flushDelayNanoseconds: UInt64
    private var events: [PhotoReviewFeedbackEvent] = []
    private var eventIDs = Set<UUID>()
    private var dedupeKeys = Set<String>()
    private var decisionSequence: UInt64 = 0
    private var archiveDirty = false
    private var profileDirty = false
    private var flushTask: Task<Void, Never>?
    private var isLoaded = false

    init(
        directoryURL: URL? = nil,
        profileStore: PhotoPreferenceProfileStore = .shared,
        persistence: any PhotoFeedbackPersisting = PhotoMLBridge.shared,
        flushDelayNanoseconds: UInt64 = PhotoFeedbackStore.flushDelayNanoseconds
    ) {
        let baseURL = directoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("PhotoDuck/learning", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("photo-feedback-events.json")
        journalURL = directory.appendingPathComponent("photo-feedback-events.journal")
        self.profileStore = profileStore
        self.persistence = persistence
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    func append(_ event: PhotoReviewFeedbackEvent) async -> Bool {
        await loadIfNeeded()
        guard appendDurably(event) else { return false }
        markPendingFlush(pruned: pruneIfNeeded())
        await persistence.persistFeedbackEvents([event])
        return true
    }

    func append(_ newEvents: [PhotoReviewFeedbackEvent]) async {
        await loadIfNeeded()
        let appendedEvents = appendBatchDurably(newEvents)
        guard !appendedEvents.isEmpty else { return }
        markPendingFlush(pruned: pruneIfNeeded())
        // Keep JSON and SQLite dedupe semantics identical. Replayed events with a
        // fresh UUID must not become duplicate training examples.
        await persistence.persistFeedbackEvents(appendedEvents)
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
        let decisionTimestamp = Date()
        let decisionToken = nextDecisionToken(at: decisionTimestamp)
        let keeperID = selectedKeeperID ?? group.keeperAssetID
        let finalKeeperID = keeperID
        // Deletion outcomes must be supplied by the caller after PhotoKit succeeds.
        // An omitted list means no deletion, never "use the recommendation."
        let resolvedDeletedIDs = dedupeIDs(deletedAssetIDs).filter { $0 != finalKeeperID }
        let resolvedKeptIDs = dedupeIDs(keptAssetIDs + (finalKeeperID.map { [$0] } ?? []))
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
            timestamp: decisionTimestamp,
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
                stage: stage,
                decisionToken: decisionToken
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
            featureSchemaVersion: Self.featureSchemaVersion,
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
        let decisionTimestamp = Date()
        let decisionToken = nextDecisionToken(at: decisionTimestamp)
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
            timestamp: decisionTimestamp,
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
                stage: stage,
                decisionToken: decisionToken
            ),
            groupID: groupID,
            deletedAssetIDs: kind == .swipeDelete ? [assetSnapshot.localIdentifier] : [],
            keptAssetIDs: kind == .swipeKeep ? [assetSnapshot.localIdentifier] : [],
            recommendationAccepted: nil,
            featureSchemaVersion: Self.featureSchemaVersion,
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
        let decisionTimestamp = Date()
        let decisionToken = nextDecisionToken(at: decisionTimestamp)
        let uniqueIDs = dedupeIDs(assetIDs)
        let assets = uniqueIDs.map { id in
            PhotoReviewFeedbackAsset(
                localIdentifier: id,
                role: .restored,
                flags: ["undoRestore"]
            )
        }
        let event = PhotoReviewFeedbackEvent(
            timestamp: decisionTimestamp,
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
                stage: .committed,
                decisionToken: decisionToken
            ),
            deletedAssetIDs: [],
            keptAssetIDs: uniqueIDs,
            recommendationAccepted: nil,
            featureSchemaVersion: Self.featureSchemaVersion,
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
        await flushPendingWrites()
        let profile = await profileStore.snapshot()
        return profile.debugSummaryLines() + ["rawEvents=\(events.count)"]
    }

    func flushPendingWrites() async {
        await loadIfNeeded()
        flushTask?.cancel()
        flushTask = nil
        await performFlush()
    }

    func clear() async {
        await loadIfNeeded()
        flushTask?.cancel()
        flushTask = nil
        events.removeAll()
        eventIDs.removeAll()
        dedupeKeys.removeAll()
        archiveDirty = true
        profileDirty = false
        _ = compactArchive()
        await profileStore.rebuild(from: [])
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true

        if let data = try? Data(contentsOf: fileURL),
           let archive = try? JSONDecoder.photoDuck.decode(PhotoFeedbackArchive.self, from: data),
           archive.schemaVersion == Self.schemaVersion {
            events = archive.events
            eventIDs = Set(archive.events.map(\.id))
            dedupeKeys = Set(archive.events.map(\.dedupeKey).filter { !$0.isEmpty })
        }

        let journalExists = FileManager.default.fileExists(atPath: journalURL.path)
        var recoveredEvent = false
        for event in loadJournalEvents() {
            recoveredEvent = appendToRawHistory(event) || recoveredEvent
        }
        let pruned = pruneIfNeeded()

        if journalExists || pruned {
            archiveDirty = true
            _ = compactArchive()
        }
        if recoveredEvent || pruned {
            await profileStore.rebuild(from: events)
        }
    }

    private func pruneIfNeeded() -> Bool {
        guard events.count > Self.maxStoredRawEvents else { return false }
        let overflow = events.count - Self.maxStoredRawEvents
        guard overflow > 0 else { return false }
        events.removeFirst(overflow)
        eventIDs = Set(events.map(\.id))
        dedupeKeys = Set(events.map(\.dedupeKey).filter { !$0.isEmpty })
        return true
    }

    private func appendDurably(_ event: PhotoReviewFeedbackEvent) -> Bool {
        guard !isDuplicate(event) else { return false }

        if appendToJournal(event) {
            appendToRawHistoryAssumingUnique(event)
            return true
        }

        // A journal failure falls back to the old atomic archive write. If both
        // writes fail, roll back the in-memory mutation rather than claiming the
        // feedback was safely accepted.
        appendToRawHistoryAssumingUnique(event)
        archiveDirty = true
        guard compactArchive() else {
            events.removeLast()
            rebuildIdentitySets()
            return false
        }
        return true
    }

    private func appendBatchDurably(_ newEvents: [PhotoReviewFeedbackEvent]) -> [PhotoReviewFeedbackEvent] {
        var candidateEventIDs = eventIDs
        var candidateDedupeKeys = dedupeKeys
        var survivors: [PhotoReviewFeedbackEvent] = []
        survivors.reserveCapacity(newEvents.count)

        for event in newEvents {
            let key = event.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidateEventIDs.insert(event.id).inserted else {
                continue
            }
            if !key.isEmpty, !candidateDedupeKeys.insert(key).inserted {
                continue
            }
            survivors.append(event)
        }
        guard !survivors.isEmpty else { return [] }

        if appendToJournal(survivors) {
            survivors.forEach(appendToRawHistoryAssumingUnique)
            return survivors
        }

        let originalCount = events.count
        survivors.forEach(appendToRawHistoryAssumingUnique)
        archiveDirty = true
        guard compactArchive() else {
            events.removeLast(events.count - originalCount)
            rebuildIdentitySets()
            return []
        }
        return survivors
    }

    private func appendToRawHistory(_ event: PhotoReviewFeedbackEvent) -> Bool {
        guard !isDuplicate(event) else { return false }
        appendToRawHistoryAssumingUnique(event)
        return true
    }

    private func appendToRawHistoryAssumingUnique(_ event: PhotoReviewFeedbackEvent) {
        let key = event.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        events.append(event)
        eventIDs.insert(event.id)
        if !key.isEmpty {
            dedupeKeys.insert(key)
        }
    }

    private func isDuplicate(_ event: PhotoReviewFeedbackEvent) -> Bool {
        if eventIDs.contains(event.id) {
            return true
        }
        let key = event.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && dedupeKeys.contains(key)
    }

    private func rebuildIdentitySets() {
        eventIDs = Set(events.map(\.id))
        dedupeKeys = Set(events.map(\.dedupeKey).filter { !$0.isEmpty })
    }

    private func markPendingFlush(pruned: Bool) {
        archiveDirty = true
        profileDirty = true
        if pruned {
            // Retention boundaries remain synchronous so a crash cannot restore
            // events that were intentionally pruned from the bounded archive.
            _ = compactArchive()
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.flushDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self.performScheduledFlush()
        }
    }

    private func performScheduledFlush() async {
        flushTask = nil
        await performFlush()
    }

    private func performFlush() async {
        if archiveDirty {
            _ = compactArchive()
        }
        if profileDirty {
            await profileStore.rebuild(from: events)
            profileDirty = false
        }
    }

    private func compactArchive() -> Bool {
        guard save() else { return false }
        try? FileManager.default.removeItem(at: journalURL)
        archiveDirty = false
        return true
    }

    private func save() -> Bool {
        let archive = PhotoFeedbackArchive(
            schemaVersion: Self.schemaVersion,
            savedAt: Date(),
            events: events
        )
        guard let data = try? JSONEncoder.photoDuck.encode(archive) else { return false }
        do {
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func appendToJournal(_ event: PhotoReviewFeedbackEvent) -> Bool {
        appendToJournal([event])
    }

    private func appendToJournal(_ events: [PhotoReviewFeedbackEvent]) -> Bool {
        var data = Data()
        for event in events {
            let entry = PhotoFeedbackJournalEntry(
                schemaVersion: Self.schemaVersion,
                event: event
            )
            guard let encodedEntry = try? JSONEncoder.photoDuck.encode(entry) else {
                return false
            }
            data.append(encodedEntry)
            data.append(0x0A)
        }

        do {
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                _ = FileManager.default.createFile(atPath: journalURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            return true
        } catch {
            return false
        }
    }

    private func loadJournalEvents() -> [PhotoReviewFeedbackEvent] {
        guard let data = try? Data(contentsOf: journalURL), !data.isEmpty else {
            return []
        }
        return data.split(separator: 0x0A).compactMap { line in
            guard let entry = try? JSONDecoder.photoDuck.decode(
                PhotoFeedbackJournalEntry.self,
                from: Data(line)
            ), entry.schemaVersion == Self.schemaVersion else {
                return nil
            }
            return entry.event
        }
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
            let role = Self.assetRole(
                assetID: asset.localIdentifier,
                kind: kind,
                suggestedKeeperID: group.keeperAssetID,
                finalKeeperID: selectedKeeperID,
                deletedAssetIDs: deletedSet,
                keptAssetIDs: keptSet,
                skipped: skipped
            )

            return asset.photoReviewFeedbackAsset(
                role: role,
                keeperAssetID: selectedKeeperID,
                similarityToKeeper: nil,
                rankingScore: candidate?.bestShotScore,
                flags: candidate?.issueFlags.map(\.title) ?? []
            )
        }
    }

    static func assetRole(
        assetID: String,
        kind: PhotoReviewDecisionKind,
        suggestedKeeperID: String?,
        finalKeeperID: String?,
        deletedAssetIDs: Set<String>,
        keptAssetIDs: Set<String>,
        skipped: Bool
    ) -> PhotoReviewAssetRole {
        // The event kind must never turn the suggested keeper into the final
        // keeper. Only the recorded final keeper ID is authoritative.
        _ = kind
        if skipped {
            return .skipped
        }
        if assetID == finalKeeperID {
            return .finalKeeper
        }
        if deletedAssetIDs.contains(assetID) {
            return .deleted
        }
        if keptAssetIDs.contains(assetID) {
            return .kept
        }
        if assetID == suggestedKeeperID {
            return .suggestedKeeper
        }
        return .candidate
    }

    private func makeDedupKey(
        source: PhotoReviewFeedbackSource,
        kind: PhotoReviewDecisionKind,
        groupID: UUID?,
        selectedKeeperID: String?,
        deletedAssetIDs: [String],
        keptAssetIDs: [String],
        stage: PhotoReviewDecisionStage,
        decisionToken: String
    ) -> String {
        Self.decisionDedupeKey(
            source: source,
            kind: kind,
            groupID: groupID,
            selectedKeeperID: selectedKeeperID,
            deletedAssetIDs: deletedAssetIDs,
            keptAssetIDs: keptAssetIDs,
            stage: stage,
            decisionToken: decisionToken
        )
    }

    static func decisionDedupeKey(
        source: PhotoReviewFeedbackSource,
        kind: PhotoReviewDecisionKind,
        groupID: UUID?,
        selectedKeeperID: String?,
        deletedAssetIDs: [String],
        keptAssetIDs: [String],
        stage: PhotoReviewDecisionStage,
        decisionToken: String
    ) -> String {
        let deleted = Array(Set(deletedAssetIDs)).sorted().joined(separator: ",")
        let kept = Array(Set(keptAssetIDs)).sorted().joined(separator: ",")
        return [
            source.rawValue,
            kind.rawValue,
            stage.rawValue,
            groupID?.uuidString ?? "none",
            selectedKeeperID ?? "none",
            deleted.isEmpty ? "none" : deleted,
            kept.isEmpty ? "none" : kept,
            decisionToken
        ].joined(separator: "|")
    }

    private func nextDecisionToken(at timestamp: Date) -> String {
        decisionSequence &+= 1
        let milliseconds = Int64(timestamp.timeIntervalSince1970 * 1_000)
        return "\(milliseconds)-\(decisionSequence)"
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

private struct PhotoFeedbackJournalEntry: Codable {
    let schemaVersion: Int
    let event: PhotoReviewFeedbackEvent
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
