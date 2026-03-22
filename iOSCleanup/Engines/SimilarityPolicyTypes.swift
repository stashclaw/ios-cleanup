import Foundation
import Photos

enum SimilarityBucket: String, Codable, Sendable, CaseIterable, Equatable {
    case nearDuplicate
    case burstShot
    case visuallySimilar
    case notSimilar
}

enum GroupConfidence: String, Codable, Sendable, CaseIterable, Equatable {
    case high
    case medium
    case low
}

enum SuggestedAction: String, Codable, Sendable, CaseIterable, Equatable {
    case suggestDeleteOthers
    case reviewTogetherOnly
    case doNotSuggestDeletion
}

enum BlockerFlag: String, Codable, Sendable, CaseIterable, Equatable {
    case screenshotMixedWithCamera
    case largeTimeGap
    case majorCompositionChange
    case differentIntent
    case editedStateDivergence
    case aspectRatioMismatch
    case dimensionMismatch
    case livePhotoVariant
    case originalVsEditedVariant
    case contentDivergence
    case burstContentDivergence
    case lowVisualEvidence
}

enum VariantRelationship: String, Codable, Sendable, CaseIterable, Equatable {
    case none
    case livePhotoToStill
    case editedToOriginal
    case hdrVariant
    case portraitDepthVariant
    case screenshotToSavedImage
}

struct SimilarityAssetDescriptor: Codable, Sendable, Hashable {
    let id: String
    let captureTimestamp: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isScreenshot: Bool
    let burstIdentifier: String?
    let isFavorite: Bool
    let isEdited: Bool
    let isLivePhoto: Bool
    let isHDR: Bool
    let isPortraitDepth: Bool
    let variantRelationshipHint: VariantRelationship

    init(
        id: String,
        captureTimestamp: Date? = nil,
        pixelWidth: Int = 1,
        pixelHeight: Int = 1,
        isScreenshot: Bool = false,
        burstIdentifier: String? = nil,
        isFavorite: Bool = false,
        isEdited: Bool = false,
        isLivePhoto: Bool = false,
        isHDR: Bool = false,
        isPortraitDepth: Bool = false,
        variantRelationshipHint: VariantRelationship = .none
    ) {
        self.id = id
        self.captureTimestamp = captureTimestamp
        self.pixelWidth = max(pixelWidth, 1)
        self.pixelHeight = max(pixelHeight, 1)
        self.isScreenshot = isScreenshot
        self.burstIdentifier = burstIdentifier
        self.isFavorite = isFavorite
        self.isEdited = isEdited
        self.isLivePhoto = isLivePhoto
        self.isHDR = isHDR
        self.isPortraitDepth = isPortraitDepth
        self.variantRelationshipHint = variantRelationshipHint
    }

    var aspectRatio: Double {
        Double(pixelWidth) / Double(max(pixelHeight, 1))
    }
}

struct SimilaritySignals: Codable, Sendable, Hashable {
    let featureDistance: Double?
    let captureTimeDeltaSeconds: Double?
    let isBurstPair: Bool
    let bothScreenshots: Bool
    let screenshotMixedWithCamera: Bool
    let aspectRatioMismatch: Bool
    let dimensionMismatch: Bool
    let variantRelationship: VariantRelationship
    let editedStateDivergence: Bool

    static func make(
        lhs: SimilarityAssetDescriptor,
        rhs: SimilarityAssetDescriptor,
        featureDistance: Double?
    ) -> SimilaritySignals {
        let timeDelta: Double?
        if let lhsDate = lhs.captureTimestamp, let rhsDate = rhs.captureTimestamp {
            timeDelta = abs(lhsDate.timeIntervalSince(rhsDate))
        } else {
            timeDelta = nil
        }

        let bothScreenshots = lhs.isScreenshot && rhs.isScreenshot
        let screenshotMixedWithCamera = lhs.isScreenshot != rhs.isScreenshot
        let aspectRatioMismatch = abs(lhs.aspectRatio - rhs.aspectRatio) > 0.18
        let widthDelta = abs(lhs.pixelWidth - rhs.pixelWidth)
        let heightDelta = abs(lhs.pixelHeight - rhs.pixelHeight)
        let dimensionMismatch = Double(widthDelta) / Double(max(lhs.pixelWidth, rhs.pixelWidth)) > 0.20
            || Double(heightDelta) / Double(max(lhs.pixelHeight, rhs.pixelHeight)) > 0.20

        return SimilaritySignals(
            featureDistance: featureDistance,
            captureTimeDeltaSeconds: timeDelta,
            isBurstPair: lhs.burstIdentifier != nil && lhs.burstIdentifier == rhs.burstIdentifier,
            bothScreenshots: bothScreenshots,
            screenshotMixedWithCamera: screenshotMixedWithCamera,
            aspectRatioMismatch: aspectRatioMismatch,
            dimensionMismatch: dimensionMismatch,
            variantRelationship: VariantRelationship.make(lhs: lhs, rhs: rhs),
            editedStateDivergence: lhs.isEdited != rhs.isEdited
        )
    }
}

struct KeeperSignals: Codable, Sendable, Hashable {
    let sharpness: Double
    let blurPenalty: Double
    let motionBlurPenalty: Double
    let eyesOpenScore: Double?
    let expressionScore: Double?
    let exposureScore: Double
    let favoriteBonus: Double
    let editedBonusOrPenalty: Double
    let framingScore: Double
    let resolutionTiebreaker: Double
}

struct ScoreBreakdown: Codable, Sendable, Hashable {
    let similarityScore: Double
    let timeScore: Double
    let burstScore: Double
    let variantScore: Double
    let screenshotPenalty: Double
    let aspectPenalty: Double
    let dimensionPenalty: Double
    let keeperScore: Double?
    let confidenceScore: Double
}

struct SimilarityPairKey: Hashable, Sendable {
    let lhsID: String
    let rhsID: String

    init(_ a: String, _ b: String) {
        if a <= b {
            lhsID = a
            rhsID = b
        } else {
            lhsID = b
            rhsID = a
        }
    }
}

struct SimilarityClusterInput: Sendable {
    let assets: [SimilarityAssetDescriptor]
    let pairwiseSignals: [SimilarityPairKey: SimilaritySignals]
    let keeperSignalsByAssetID: [String: KeeperSignals]

    init(
        assets: [SimilarityAssetDescriptor],
        pairwiseSignals: [SimilarityPairKey: SimilaritySignals] = [:],
        keeperSignalsByAssetID: [String: KeeperSignals] = [:]
    ) {
        self.assets = assets
        self.pairwiseSignals = pairwiseSignals
        self.keeperSignalsByAssetID = keeperSignalsByAssetID
    }
}

struct PairEligibilityResult: Codable, Sendable, Hashable {
    let eligible: Bool
    let provisionalBucket: SimilarityBucket
    let hardBlockers: [BlockerFlag]
    let softBlockers: [BlockerFlag]
    let similarityScore: Double
    let reasonStrings: [String]
}

struct KeeperRankingResult: Codable, Sendable, Hashable {
    let keeperAssetID: String?
    let rankedAssetIDs: [String]
    let scoreByAssetID: [String: Double]
    let reasonsByAssetID: [String: [String]]
    let scoreBreakdownByAssetID: [String: KeeperSignals]
}

struct SimilarityGroupResult: Codable, Sendable, Hashable {
    let bucket: SimilarityBucket
    let confidence: GroupConfidence
    let action: SuggestedAction
    let keeperAssetID: String?
    let deleteCandidateIDs: [String]
    let reasons: [String]
    let blockerFlags: [BlockerFlag]
    let scoreBreakdown: ScoreBreakdown
}

enum SimilarityThresholds {
    static let burstWindowSeconds: Double = 3
    static let nearDuplicateWindowSeconds: Double = 20
    static let visualSessionWindowSeconds: Double = 15 * 60
    static let extendedSessionWindowSeconds: Double = 60 * 60

    static let maxNearDuplicateFeatureDistance: Double = 0.05
    static let maxVisualSimilarFeatureDistance: Double = 0.12
    static let maxBurstFeatureDistance: Double = 0.16

    static let aspectRatioMismatchPenalty: Double = 0.08
    static let dimensionMismatchPenalty: Double = 0.05
    static let largeTimeGapPenaltyAfterSeconds: Double = 120

    static let hardDeleteRecommendationConfidenceFloor: Double = 0.80
    static let nearDuplicateDowngradeDistanceFloor: Double = 0.06
    static let visualSimilarityDowngradeDistanceFloor: Double = 0.14

    static let burstConfidenceBonus: Double = 0.10
    static let screenshotPenalty: Double = 0.20
    static let variantSoftPenalty: Double = 0.06

    static let strongLinkFloor: Double = 0.55
    static let nearDuplicateClusterFloor: Double = 0.45
    static let visualClusterFloor: Double = 0.25
    static let splitConsistencyFloor: Double = 0.30
}

extension SimilarityBucket {
    var photoGroupReason: PhotoGroup.SimilarityReason? {
        switch self {
        case .nearDuplicate:
            return .nearDuplicate
        case .burstShot:
            return .burstShot
        case .visuallySimilar:
            return .visuallySimilar
        case .notSimilar:
            return nil
        }
    }
}

extension GroupConfidence {
    var photoGroupConfidence: SimilarGroupConfidence {
        switch self {
        case .high:
            return .high
        case .medium:
            return .medium
        case .low:
            return .low
        }
    }

    var suggestedAction: SuggestedAction {
        switch self {
        case .high:
            return .suggestDeleteOthers
        case .medium, .low:
            return .reviewTogetherOnly
        }
    }
}

extension SuggestedAction {
    var photoGroupAction: SimilarRecommendedAction {
        switch self {
        case .suggestDeleteOthers:
            return .keepBestTrashRest
        case .reviewTogetherOnly:
            return .reviewManually
        case .doNotSuggestDeletion:
            return .keepAll
        }
    }
}

extension VariantRelationship {
    static func make(lhs: SimilarityAssetDescriptor, rhs: SimilarityAssetDescriptor) -> VariantRelationship {
        if lhs.isScreenshot != rhs.isScreenshot {
            return .screenshotToSavedImage
        }
        if lhs.isLivePhoto != rhs.isLivePhoto {
            return .livePhotoToStill
        }
        if lhs.isEdited != rhs.isEdited {
            return .editedToOriginal
        }
        if lhs.isHDR != rhs.isHDR {
            return .hdrVariant
        }
        if lhs.isPortraitDepth != rhs.isPortraitDepth {
            return .portraitDepthVariant
        }
        return .none
    }
}

enum SimilaritySignalBuilder {
    static func descriptor(for asset: PHAsset) -> SimilarityAssetDescriptor {
        let isEdited: Bool
        if let creationDate = asset.creationDate, let modificationDate = asset.modificationDate {
            isEdited = abs(modificationDate.timeIntervalSince(creationDate)) > 1
        } else {
            isEdited = false
        }

        return SimilarityAssetDescriptor(
            id: asset.localIdentifier,
            captureTimestamp: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            burstIdentifier: asset.burstIdentifier,
            isFavorite: asset.isFavorite,
            isEdited: isEdited,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isHDR: asset.mediaSubtypes.contains(.photoHDR),
            isPortraitDepth: asset.mediaSubtypes.contains(.photoDepthEffect)
        )
    }

    static func keeperSignals(for asset: PHAsset) -> KeeperSignals {
        let pixels = Double(max(asset.pixelWidth * asset.pixelHeight, 1))
        let resolutionScore = min(log10(pixels) / 8.0, 1.0)
        let aspect = Double(asset.pixelWidth) / max(Double(asset.pixelHeight), 1)
        let aspectDistance = min(abs(aspect - 1.0), abs(aspect - 4.0 / 3.0), abs(aspect - 3.0 / 4.0))
        let framingScore = max(0.0, 1.0 - min(aspectDistance, 1.0))
        let favoriteBonus = asset.isFavorite ? 0.08 : 0.0
        let screenshotBonus = asset.mediaSubtypes.contains(.photoScreenshot) ? 0.18 : 0.0

        let isEdited: Bool
        if let creationDate = asset.creationDate, let modificationDate = asset.modificationDate {
            isEdited = abs(modificationDate.timeIntervalSince(creationDate)) > 1
        } else {
            isEdited = false
        }

        return KeeperSignals(
            sharpness: resolutionScore,
            blurPenalty: max(0.0, 1.0 - resolutionScore) * 0.65,
            motionBlurPenalty: 0.0,
            eyesOpenScore: nil,
            expressionScore: nil,
            exposureScore: 0.72 + (favoriteBonus > 0 ? 0.08 : 0.0) + screenshotBonus * 0.25,
            favoriteBonus: favoriteBonus,
            editedBonusOrPenalty: isEdited ? -0.02 : 0.0,
            framingScore: framingScore,
            resolutionTiebreaker: resolutionScore * 0.2
        )
    }
}

extension SimilaritySignals {
    var isStrongVisualMatch: Bool {
        guard let featureDistance else { return false }
        return featureDistance <= SimilarityThresholds.maxNearDuplicateFeatureDistance
    }

    var isModerateVisualMatch: Bool {
        guard let featureDistance else { return false }
        return featureDistance <= SimilarityThresholds.maxVisualSimilarFeatureDistance
    }

    var captureTimeDelta: Double {
        captureTimeDeltaSeconds ?? .greatestFiniteMagnitude
    }
}

extension PhotoGroup {
    func similarityClusterInput(baseFeatureDistance: Double? = nil) -> SimilarityClusterInput {
        let descriptors = assets.map { SimilaritySignalBuilder.descriptor(for: $0) }
        let keeperSignals = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.localIdentifier, SimilaritySignalBuilder.keeperSignals(for: $0)) }
        )

        var pairwiseSignals: [SimilarityPairKey: SimilaritySignals] = [:]
        for lhsIndex in descriptors.indices {
            for rhsIndex in descriptors.indices where rhsIndex > lhsIndex {
                let lhs = descriptors[lhsIndex]
                let rhs = descriptors[rhsIndex]
                pairwiseSignals[SimilarityPairKey(lhs.id, rhs.id)] = SimilaritySignals.make(
                    lhs: lhs,
                    rhs: rhs,
                    featureDistance: baseFeatureDistance ?? Double(similarity)
                )
            }
        }

        return SimilarityClusterInput(
            assets: descriptors,
            pairwiseSignals: pairwiseSignals,
            keeperSignalsByAssetID: keeperSignals
        )
    }
}
