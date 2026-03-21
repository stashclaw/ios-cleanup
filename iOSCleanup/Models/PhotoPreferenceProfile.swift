import Foundation

struct PhotoDecisionAggregate: Codable, Sendable, Hashable {
    var reviewedCount: Int = 0
    var keptCount: Int = 0
    var deletedCount: Int = 0
    var skippedCount: Int = 0
    var overrideCount: Int = 0
    var acceptedRecommendationCount: Int = 0
    var rejectedRecommendationCount: Int = 0
    var undoCount: Int = 0

    var totalActions: Int {
        reviewedCount + keptCount + deletedCount + skippedCount + overrideCount + undoCount
    }

    mutating func merge(_ other: PhotoDecisionAggregate) {
        reviewedCount += other.reviewedCount
        keptCount += other.keptCount
        deletedCount += other.deletedCount
        skippedCount += other.skippedCount
        overrideCount += other.overrideCount
        acceptedRecommendationCount += other.acceptedRecommendationCount
        rejectedRecommendationCount += other.rejectedRecommendationCount
        undoCount += other.undoCount
    }

    var keeperAcceptanceRate: Double {
        let total = acceptedRecommendationCount + rejectedRecommendationCount
        guard total > 0 else { return 0 }
        return Double(acceptedRecommendationCount) / Double(total)
    }

    var deleteRate: Double {
        let total = reviewedCount
        guard total > 0 else { return 0 }
        return Double(deletedCount) / Double(total)
    }

    var skipRate: Double {
        let total = reviewedCount
        guard total > 0 else { return 0 }
        return Double(skippedCount) / Double(total)
    }

    var overrideRate: Double {
        let total = reviewedCount
        guard total > 0 else { return 0 }
        return Double(overrideCount) / Double(total)
    }
}

struct PhotoPreferenceProfile: Codable, Sendable, Hashable {
    static let schemaVersion = 1

    var schemaVersion: Int = Self.schemaVersion
    var updatedAt: Date = Date()
    var totalRawEvents: Int = 0
    var totalCommittedEvents: Int = 0
    var overall: PhotoDecisionAggregate = .init()
    var bySource: [String: PhotoDecisionAggregate] = [:]
    var byGroupType: [String: PhotoDecisionAggregate] = [:]
    var byBucket: [String: PhotoDecisionAggregate] = [:]
    var screenshots: PhotoDecisionAggregate = .init()
    var bursts: PhotoDecisionAggregate = .init()
    var edited: PhotoDecisionAggregate = .init()
    var favorites: PhotoDecisionAggregate = .init()
    var lowConfidence: PhotoDecisionAggregate = .init()

    mutating func merge(_ other: PhotoPreferenceProfile) {
        updatedAt = max(updatedAt, other.updatedAt)
        totalRawEvents += other.totalRawEvents
        totalCommittedEvents += other.totalCommittedEvents
        overall.merge(other.overall)
        let sourceAggregates = other.bySource
        let groupTypeAggregates = other.byGroupType
        let bucketAggregates = other.byBucket
        var mergedBySource = bySource
        var mergedByGroupType = byGroupType
        var mergedByBucket = byBucket
        Self.merge(into: &mergedBySource, sourceAggregates)
        Self.merge(into: &mergedByGroupType, groupTypeAggregates)
        Self.merge(into: &mergedByBucket, bucketAggregates)
        bySource = mergedBySource
        byGroupType = mergedByGroupType
        byBucket = mergedByBucket
        screenshots.merge(other.screenshots)
        bursts.merge(other.bursts)
        edited.merge(other.edited)
        favorites.merge(other.favorites)
        lowConfidence.merge(other.lowConfidence)
    }

    var keeperAcceptanceRate: Double {
        overall.keeperAcceptanceRate
    }

    var overrideRate: Double {
        overall.overrideRate
    }

    var deleteRate: Double {
        overall.deleteRate
    }

    var skipRate: Double {
        overall.skipRate
    }

    func aggregate(forGroupType groupType: SimilarGroupType?) -> PhotoDecisionAggregate? {
        guard let groupType else { return nil }
        return byGroupType[groupType.rawValue]
    }

    func aggregate(forBucket bucket: SimilarityBucket?) -> PhotoDecisionAggregate? {
        guard let bucket else { return nil }
        return byBucket[bucket.rawValue]
    }

    func debugSummaryLines() -> [String] {
        let groupTypeParts = byGroupType.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.totalActions)" }
        let bucketParts = byBucket.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.totalActions)" }
        return [
            "events=\(totalRawEvents) committed=\(totalCommittedEvents)",
            String(format: "accept=%.2f delete=%.2f skip=%.2f override=%.2f", keeperAcceptanceRate, deleteRate, skipRate, overrideRate),
            "byGroupType: \(groupTypeParts.joined(separator: ", "))",
            "byBucket: \(bucketParts.joined(separator: ", "))"
        ]
    }

    private static func merge(into dictionary: inout [String: PhotoDecisionAggregate], _ other: [String: PhotoDecisionAggregate]) {
        for (key, value) in other {
            dictionary[key, default: .init()].merge(value)
        }
    }
}
