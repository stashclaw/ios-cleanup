import Foundation
import Photos

enum PhotoReviewFeedbackSource: String, Codable, Sendable, CaseIterable {
    case similarGroupReview
    case swipeMode
    case deleteManager
    case photoResults
    case homeView
    case unknown
}

enum PhotoReviewDecisionKind: String, Codable, Sendable, CaseIterable {
    case keepBest
    case keeperOverride
    case deleteSelected
    case skipGroup
    case swipeKeep
    case swipeDelete
    case restoreUndo
    case editPreferenceSignal
}

enum PhotoReviewDecisionStage: String, Codable, Sendable, CaseIterable {
    case provisional
    case committed
    case reverted
}

enum PhotoReviewAssetRole: String, Codable, Sendable, CaseIterable {
    case suggestedKeeper
    case finalKeeper
    case deleted
    case kept
    case skipped
    case candidate
    case overriddenKeeper
    case restored
    case unknown
}

struct PhotoReviewFeedbackAsset: Codable, Sendable, Hashable, Identifiable {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool?
    let isEdited: Bool?
    let isScreenshot: Bool?
    let burstIdentifier: String?
    let role: PhotoReviewAssetRole
    let similarityToKeeper: Double?
    let rankingScore: Double?
    let flags: [String]

    var id: String { localIdentifier }

    init(
        localIdentifier: String,
        creationDate: Date? = nil,
        pixelWidth: Int = 1,
        pixelHeight: Int = 1,
        isFavorite: Bool? = nil,
        isEdited: Bool? = nil,
        isScreenshot: Bool? = nil,
        burstIdentifier: String? = nil,
        role: PhotoReviewAssetRole = .unknown,
        similarityToKeeper: Double? = nil,
        rankingScore: Double? = nil,
        flags: [String] = []
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.pixelWidth = max(pixelWidth, 1)
        self.pixelHeight = max(pixelHeight, 1)
        self.isFavorite = isFavorite
        self.isEdited = isEdited
        self.isScreenshot = isScreenshot
        self.burstIdentifier = burstIdentifier
        self.role = role
        self.similarityToKeeper = similarityToKeeper
        self.rankingScore = rankingScore
        self.flags = flags
    }

    var hasBurstIdentifier: Bool {
        burstIdentifier != nil
    }
}

struct PhotoReviewFeedbackEvent: Codable, Sendable, Hashable, Identifiable {
    static let currentPolicyVersion = 1
    static let currentModelVersion = 1
    static let currentFeatureSchemaVersion = 1

    let id: UUID
    let timestamp: Date
    let source: PhotoReviewFeedbackSource
    let kind: PhotoReviewDecisionKind
    let stage: PhotoReviewDecisionStage
    let dedupeKey: String
    let groupID: UUID?
    let groupType: SimilarGroupType?
    let bucket: SimilarityBucket?
    let confidence: GroupConfidence?
    let suggestedAction: SuggestedAction?
    let suggestedKeeperAssetID: String?
    let finalKeeperAssetID: String?
    let deletedAssetIDs: [String]
    let keptAssetIDs: [String]
    let skipped: Bool
    let recommendationAccepted: Bool?
    let policyVersion: Int
    let modelVersion: Int
    let featureSchemaVersion: Int
    let assets: [PhotoReviewFeedbackAsset]
    let note: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: PhotoReviewFeedbackSource,
        kind: PhotoReviewDecisionKind,
        stage: PhotoReviewDecisionStage = .committed,
        dedupeKey: String,
        groupID: UUID? = nil,
        groupType: SimilarGroupType? = nil,
        bucket: SimilarityBucket? = nil,
        confidence: GroupConfidence? = nil,
        suggestedAction: SuggestedAction? = nil,
        suggestedKeeperAssetID: String? = nil,
        finalKeeperAssetID: String? = nil,
        deletedAssetIDs: [String] = [],
        keptAssetIDs: [String] = [],
        skipped: Bool = false,
        recommendationAccepted: Bool? = nil,
        policyVersion: Int = Self.currentPolicyVersion,
        modelVersion: Int = Self.currentModelVersion,
        featureSchemaVersion: Int = Self.currentFeatureSchemaVersion,
        assets: [PhotoReviewFeedbackAsset] = [],
        note: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.kind = kind
        self.stage = stage
        self.dedupeKey = dedupeKey
        self.groupID = groupID
        self.groupType = groupType
        self.bucket = bucket
        self.confidence = confidence
        self.suggestedAction = suggestedAction
        self.suggestedKeeperAssetID = suggestedKeeperAssetID
        self.finalKeeperAssetID = finalKeeperAssetID
        self.deletedAssetIDs = Self.uniqueIDs(deletedAssetIDs)
        self.keptAssetIDs = Self.uniqueIDs(keptAssetIDs)
        self.skipped = skipped
        self.recommendationAccepted = recommendationAccepted
        self.policyVersion = policyVersion
        self.modelVersion = modelVersion
        self.featureSchemaVersion = featureSchemaVersion
        self.assets = assets
        self.note = note
    }

    var assetIdentifiers: [String] {
        assets.map(\.localIdentifier)
    }

    var committedDecision: Bool {
        stage == .committed
    }

    var rawByteEstimate: Int {
        // Metadata only: the payload should stay tiny and never persist image blobs.
        // This is just a rough guardrail for the on-device JSON archive size.
        256 + assets.count * 256
    }

    private static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

struct PhotoTrainingFeatureVector: Codable, Sendable, Hashable {
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool?
    let isEdited: Bool?
    let isScreenshot: Bool
    let burstIdentifierPresent: Bool
    let similarityToKeeper: Double?
    let rankingScore: Double?
    let flags: [String]
}

enum PhotoTrainingRowKind: String, Codable, Sendable, CaseIterable, Equatable {
    case assetPreference
    case groupOutcome
    case keeperRanking
}

struct PhotoTrainingExportRow: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let eventID: UUID
    let kind: PhotoTrainingRowKind
    let timestamp: Date
    let groupID: UUID?
    let assetID: String?
    let assetRole: PhotoReviewAssetRole
    let outcomeLabel: String
    let bucket: SimilarityBucket?
    let groupType: SimilarGroupType?
    let confidence: GroupConfidence?
    let suggestedAction: SuggestedAction?
    let recommendationAccepted: Bool?
    let keeperAssetID: String?
    let rankingScore: Double?
    let similarityToKeeper: Double?
    let policyVersion: Int
    let modelVersion: Int
    let featureSchemaVersion: Int
    let featureVector: PhotoTrainingFeatureVector?
}

extension PHAsset {
    func photoReviewFeedbackAsset(
        role: PhotoReviewAssetRole = .unknown,
        keeperAssetID: String? = nil,
        similarityToKeeper: Double? = nil,
        rankingScore: Double? = nil,
        flags: [String] = []
    ) -> PhotoReviewFeedbackAsset {
        let isEdited: Bool?
        if let creationDate, let modificationDate {
            isEdited = abs(modificationDate.timeIntervalSince(creationDate)) > 1
        } else {
            isEdited = nil
        }

        return PhotoReviewFeedbackAsset(
            localIdentifier: localIdentifier,
            creationDate: creationDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isFavorite: isFavorite,
            isEdited: isEdited,
            isScreenshot: mediaSubtypes.contains(.photoScreenshot),
            burstIdentifier: burstIdentifier,
            role: role,
            similarityToKeeper: similarityToKeeper,
            rankingScore: rankingScore,
            flags: flags
        )
    }
}
