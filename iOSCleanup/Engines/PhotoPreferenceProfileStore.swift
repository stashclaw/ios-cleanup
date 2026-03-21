import Foundation

actor PhotoPreferenceProfileStore {
    static let shared = PhotoPreferenceProfileStore()

    static let schemaVersion = PhotoPreferenceProfile.schemaVersion

    private let fileURL: URL
    private var profile: PhotoPreferenceProfile
    private var isLoaded = false

    init(directoryURL: URL? = nil) {
        let baseURL = directoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("PhotoDuck/learning", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("photo-preference-profile.json")
        profile = PhotoPreferenceProfile()
    }

    func snapshot() async -> PhotoPreferenceProfile {
        await loadIfNeeded()
        return profile
    }

    func apply(_ event: PhotoReviewFeedbackEvent) async {
        await loadIfNeeded()
        profile.totalRawEvents += 1
        guard event.stage == .committed else {
            profile.updatedAt = max(profile.updatedAt, event.timestamp)
            save()
            return
        }

        profile.totalCommittedEvents += 1
        profile.updatedAt = max(profile.updatedAt, event.timestamp)

        let delta = aggregateDelta(for: event)
        profile.overall.merge(delta)
        if let groupType = event.groupType?.rawValue {
            profile.byGroupType[groupType, default: .init()].merge(delta)
        }
        if let bucket = event.bucket?.rawValue {
            profile.byBucket[bucket, default: .init()].merge(delta)
        }

        if event.assets.contains(where: { $0.isScreenshot == true }) {
            profile.screenshots.merge(delta)
        }
        if event.assets.contains(where: { $0.burstIdentifier != nil }) {
            profile.bursts.merge(delta)
        }
        if event.assets.contains(where: { $0.isEdited == true }) {
            profile.edited.merge(delta)
        }
        if event.assets.contains(where: { $0.isFavorite == true }) {
            profile.favorites.merge(delta)
        }
        if event.confidence == .low {
            profile.lowConfidence.merge(delta)
        }

        save()
    }

    func approximateDiskFootprintBytes() async -> Int64 {
        await loadIfNeeded()
        guard let data = try? JSONEncoder.photoDuck.encode(profile) else { return 0 }
        return Int64(data.count)
    }

    func debugSummaryLines() async -> [String] {
        await loadIfNeeded()
        return profile.debugSummaryLines()
    }

    func reset() async {
        await loadIfNeeded()
        profile = PhotoPreferenceProfile()
        save()
    }

    private func aggregateDelta(for event: PhotoReviewFeedbackEvent) -> PhotoDecisionAggregate {
        var aggregate = PhotoDecisionAggregate(reviewedCount: 1)

        switch event.kind {
        case .keepBest, .swipeKeep:
            aggregate.keptCount = 1
        case .keeperOverride:
            aggregate.overrideCount = 1
        case .deleteSelected, .swipeDelete:
            aggregate.deletedCount = max(event.deletedAssetIDs.count, 1)
        case .skipGroup:
            aggregate.skippedCount = 1
        case .restoreUndo:
            aggregate.undoCount = 1
        case .editPreferenceSignal:
            break
        }

        if let recommendationAccepted = event.recommendationAccepted {
            if recommendationAccepted {
                aggregate.acceptedRecommendationCount = 1
            } else {
                aggregate.rejectedRecommendationCount = 1
            }
        }

        return aggregate
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let archive = try? JSONDecoder.photoDuck.decode(PhotoPreferenceProfileArchive.self, from: data) else { return }
        guard archive.schemaVersion == Self.schemaVersion else { return }
        profile = archive.profile
    }

    private func save() {
        let archive = PhotoPreferenceProfileArchive(
            schemaVersion: Self.schemaVersion,
            savedAt: Date(),
            profile: profile
        )
        guard let data = try? JSONEncoder.photoDuck.encode(archive) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

private struct PhotoPreferenceProfileArchive: Codable {
    let schemaVersion: Int
    let savedAt: Date
    let profile: PhotoPreferenceProfile
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

