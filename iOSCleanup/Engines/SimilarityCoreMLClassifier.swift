import CoreML
import OSLog
import Photos

// MARK: - Protocols

protocol KeeperPredictionService: Sendable {
    func predictKeeper(features: KeeperPredictionInput) async -> KeeperPredictionOutput?
    var isAvailable: Bool { get }
}

protocol GroupActionPredictionService: Sendable {
    func predictAction(features: GroupActionPredictionInput) async -> GroupActionPredictionOutput?
    var isAvailable: Bool { get }
}

// MARK: - Input/Output Types

struct KeeperPredictionInput: Sendable {
    let bucket: String
    let groupType: String
    let confidence: String
    let suggestedAction: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let isEdited: Bool
    let isScreenshot: Bool
    let burstPresent: Bool
    let rankingScore: Double
    let similarityToKeeper: Double
    let aspectRatio: Double
    let fileSizeBytes: Int64
}

enum KeeperFeatureSchema {
    static let outcomeLabel = "outcome_label"
    static let trainingMetadataNames: [String] = [
        "event_id", "group_id", "feature_schema_version", "active_choice"
    ]
    static let modelInputNames: [String] = [
        "bucket", "group_type", "confidence", "suggested_action",
        "pixel_width", "pixel_height", "is_favorite", "is_edited",
        "is_screenshot", "burst_present", "ranking_score",
        "similarity_to_keeper", "aspect_ratio", "file_size_bytes"
    ]
    static let exportHeaders = [outcomeLabel] + trainingMetadataNames + modelInputNames
}

struct KeeperPredictionOutput: Sendable {
    let predictedLabel: String       // "keeper", "suggested_keeper", "candidate"
    let keeperProbability: Double    // probability of being the keeper
    let candidateProbability: Double
}

struct GroupActionPredictionInput: Sendable {
    let bucket: String
    let groupType: String
    let confidence: String
    let suggestedAction: String
    let assetCount: Int
    let avgRanking: Double
    let screenshotCount: Int
    let favoriteCount: Int
    let editedCount: Int
}

enum GroupActionFeatureSchema {
    static let outcomeLabel = "outcome_label"
    static let trainingMetadataNames: [String] = [
        "event_id", "group_id", "feature_schema_version"
    ]
    static let modelInputNames: [String] = [
        "bucket", "group_type", "confidence", "suggested_action",
        "asset_count", "avg_ranking", "screenshot_count",
        "favorite_count", "edited_count"
    ]
    static let exportHeaders = [outcomeLabel] + trainingMetadataNames + modelInputNames
}

struct GroupActionPredictionOutput: Sendable {
    let predictedLabel: String       // "keep_best_keeper", "deleted", "skipped", etc.
    let labelProbabilities: [String: Double]
}

enum OptionalMLModelLoadStatus: Sendable, Equatable {
    case notBundled
    case notLoaded
    case available
    case failed(String)
}

// MARK: - ML Keeper Ranking Service

actor MLKeeperRankingService: KeeperPredictionService {
    static let shared = MLKeeperRankingService()

    private static let logger = Logger(
        subsystem: "com.photoduck.iOSCleanup",
        category: "MLKeeperModel"
    )

    private let modelURL: URL?
    private var model: MLModel?
    private var loadStatusValue: OptionalMLModelLoadStatus
    nonisolated let isAvailable: Bool

    init(modelName: String = "PhotoDuckKeeper") {
        let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
        modelURL = url
        model = nil
        isAvailable = url != nil
        loadStatusValue = url == nil ? .notBundled : .notLoaded
    }

    func predictKeeper(features: KeeperPredictionInput) async -> KeeperPredictionOutput? {
        guard let model = loadModelIfNeeded() else { return nil }

        let provider = KeeperFeatureProvider(input: features)
        let prediction: MLFeatureProvider
        do {
            prediction = try model.prediction(from: provider)
        } catch {
            Self.logger.error(
                "Keeper inference failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        let label = prediction.featureValue(for: "outcome_label")?.stringValue ?? "candidate"
        let probsDict = prediction.featureValue(for: "outcome_labelProbability")?.dictionaryValue as? [String: Double] ?? [:]

        return KeeperPredictionOutput(
            predictedLabel: label,
            keeperProbability: probsDict["keeper"] ?? 0,
            candidateProbability: probsDict["candidate"] ?? 0
        )
    }

    func loadStatus() -> OptionalMLModelLoadStatus {
        loadStatusValue
    }

    private func loadModelIfNeeded() -> MLModel? {
        if let model {
            return model
        }
        guard case .notLoaded = loadStatusValue, let modelURL else {
            return nil
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let loadedModel = try MLModel(contentsOf: modelURL, configuration: config)
            model = loadedModel
            loadStatusValue = .available
            return loadedModel
        } catch {
            let message = error.localizedDescription
            loadStatusValue = .failed(message)
            Self.logger.error(
                "Keeper model exists but failed to load: \(message, privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - ML Group Action Service

actor MLGroupActionService: GroupActionPredictionService {
    static let shared = MLGroupActionService()

    private static let logger = Logger(
        subsystem: "com.photoduck.iOSCleanup",
        category: "MLGroupActionModel"
    )

    private let modelURL: URL?
    private var model: MLModel?
    private var loadStatusValue: OptionalMLModelLoadStatus
    nonisolated let isAvailable: Bool

    init(modelName: String = "PhotoDuckGroupAction") {
        let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
        modelURL = url
        model = nil
        isAvailable = url != nil
        loadStatusValue = url == nil ? .notBundled : .notLoaded
    }

    func predictAction(features: GroupActionPredictionInput) async -> GroupActionPredictionOutput? {
        guard let model = loadModelIfNeeded() else { return nil }

        let provider = GroupActionFeatureProvider(input: features)
        let prediction: MLFeatureProvider
        do {
            prediction = try model.prediction(from: provider)
        } catch {
            Self.logger.error(
                "Group-action inference failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        let label = prediction.featureValue(for: "outcome_label")?.stringValue ?? "skipped"
        let probsDict = prediction.featureValue(for: "outcome_labelProbability")?.dictionaryValue as? [String: Double] ?? [:]

        return GroupActionPredictionOutput(
            predictedLabel: label,
            labelProbabilities: probsDict
        )
    }

    func loadStatus() -> OptionalMLModelLoadStatus {
        loadStatusValue
    }

    private func loadModelIfNeeded() -> MLModel? {
        if let model {
            return model
        }
        guard case .notLoaded = loadStatusValue, let modelURL else {
            return nil
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let loadedModel = try MLModel(contentsOf: modelURL, configuration: config)
            model = loadedModel
            loadStatusValue = .available
            return loadedModel
        } catch {
            let message = error.localizedDescription
            loadStatusValue = .failed(message)
            Self.logger.error(
                "Group-action model exists but failed to load: \(message, privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - Feature Providers

final class KeeperFeatureProvider: MLFeatureProvider {
    let input: KeeperPredictionInput

    init(input: KeeperPredictionInput) {
        self.input = input
    }

    var featureNames: Set<String> {
        Set(KeeperFeatureSchema.modelInputNames)
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "bucket": return MLFeatureValue(string: input.bucket)
        case "group_type": return MLFeatureValue(string: input.groupType)
        case "confidence": return MLFeatureValue(string: input.confidence)
        case "suggested_action": return MLFeatureValue(string: input.suggestedAction)
        case "pixel_width": return MLFeatureValue(int64: Int64(input.pixelWidth))
        case "pixel_height": return MLFeatureValue(int64: Int64(input.pixelHeight))
        case "is_favorite": return MLFeatureValue(int64: input.isFavorite ? 1 : 0)
        case "is_edited": return MLFeatureValue(int64: input.isEdited ? 1 : 0)
        case "is_screenshot": return MLFeatureValue(int64: input.isScreenshot ? 1 : 0)
        case "burst_present": return MLFeatureValue(int64: input.burstPresent ? 1 : 0)
        case "ranking_score": return MLFeatureValue(double: input.rankingScore)
        case "similarity_to_keeper": return MLFeatureValue(double: input.similarityToKeeper)
        case "aspect_ratio": return MLFeatureValue(double: input.aspectRatio)
        case "file_size_bytes": return MLFeatureValue(int64: input.fileSizeBytes)
        default: return nil
        }
    }
}

final class GroupActionFeatureProvider: MLFeatureProvider {
    let input: GroupActionPredictionInput

    init(input: GroupActionPredictionInput) {
        self.input = input
    }

    var featureNames: Set<String> {
        Set(GroupActionFeatureSchema.modelInputNames)
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "bucket": return MLFeatureValue(string: input.bucket)
        case "group_type": return MLFeatureValue(string: input.groupType)
        case "confidence": return MLFeatureValue(string: input.confidence)
        case "suggested_action": return MLFeatureValue(string: input.suggestedAction)
        case "asset_count": return MLFeatureValue(int64: Int64(input.assetCount))
        case "avg_ranking": return MLFeatureValue(double: input.avgRanking)
        case "screenshot_count": return MLFeatureValue(int64: Int64(input.screenshotCount))
        case "favorite_count": return MLFeatureValue(int64: Int64(input.favoriteCount))
        case "edited_count": return MLFeatureValue(int64: Int64(input.editedCount))
        default: return nil
        }
    }
}

// MARK: - Convenience: Build prediction inputs from domain types

struct KeeperInferenceGroupContext: Sendable {
    let bucket: String
    let groupType: String
    let confidence: String
    let suggestedAction: String

    init(cluster: SimilarityClusterInput) {
        let descriptorsByID = Dictionary(
            uniqueKeysWithValues: cluster.assets.map { ($0.id, $0) }
        )
        let pairClassifier = ConservativePairSimilarityClassifier()
        let pairResults = cluster.pairwiseSignals.compactMap { key, signals -> PairEligibilityResult? in
            guard let lhs = descriptorsByID[key.lhsID],
                  let rhs = descriptorsByID[key.rhsID] else {
                return nil
            }
            return pairClassifier.classifyPair(lhs: lhs, rhs: rhs, signals: signals)
        }
        let eligibleResults = pairResults.filter(\.eligible)
        let burstIDs = Set(cluster.assets.compactMap(\.burstIdentifier))
        let isSingleBurst = burstIDs.count == 1
            && cluster.assets.allSatisfy { $0.burstIdentifier != nil }
        let hasContextPenalty = cluster.pairwiseSignals.values.contains { signals in
            signals.screenshotMixedWithCamera
                || signals.aspectRatioMismatch
                || signals.dimensionMismatch
                || signals.editedStateDivergence
        }
        let minimumPairScore = eligibleResults.map(\.similarityScore).min() ?? 0

        let resolvedBucket: SimilarityBucket
        if isSingleBurst {
            resolvedBucket = .burstShot
        } else if !eligibleResults.isEmpty,
                  eligibleResults.allSatisfy({ $0.provisionalBucket == .nearDuplicate }) {
            resolvedBucket = .nearDuplicate
        } else {
            resolvedBucket = .visuallySimilar
        }

        let resolvedConfidence: GroupConfidence
        switch resolvedBucket {
        case .burstShot:
            resolvedConfidence = !hasContextPenalty
                && minimumPairScore >= SimilarityThresholds.burstAutoDeleteScoreFloor
                ? .high
                : .medium
        case .nearDuplicate:
            resolvedConfidence = !hasContextPenalty
                && minimumPairScore >= SimilarityThresholds.nearDuplicateAutoDeleteScoreFloor
                ? .high
                : .medium
        case .visuallySimilar:
            resolvedConfidence = eligibleResults.isEmpty || hasContextPenalty ? .low : .medium
        case .notSimilar:
            resolvedConfidence = .low
        }

        bucket = resolvedBucket.rawValue
        switch resolvedBucket {
        case .burstShot:
            groupType = SimilarGroupType.burst.rawValue
        case .nearDuplicate:
            groupType = SimilarGroupType.nearDuplicate.rawValue
        case .visuallySimilar:
            groupType = SimilarGroupType.sameMoment.rawValue
        case .notSimilar:
            groupType = SimilarGroupType.unknown.rawValue
        }
        confidence = resolvedConfidence.rawValue
        suggestedAction = resolvedConfidence == .high && resolvedBucket != .visuallySimilar
            ? SimilarRecommendedAction.keepBestTrashRest.rawValue
            : SimilarRecommendedAction.reviewManually.rawValue
    }
}

extension KeeperPredictionInput {
    init?(
        asset: SimilarityAssetDescriptor,
        cluster: SimilarityClusterInput,
        groupContext: KeeperInferenceGroupContext,
        heuristicResult: KeeperRankingResult
    ) {
        guard let heuristicKeeperID = heuristicResult.keeperAssetID,
              let rankingScore = heuristicResult.scoreByAssetID[asset.id] else {
            return nil
        }

        let similarityToKeeper: Double
        if asset.id == heuristicKeeperID {
            similarityToKeeper = 0
        } else {
            guard let featureDistance = cluster.pairwiseSignals[
                SimilarityPairKey(asset.id, heuristicKeeperID)
            ]?.featureDistance,
            featureDistance.isFinite,
            featureDistance >= 0 else {
                // Missing visual context must not be replaced by a constant training feature.
                return nil
            }
            similarityToKeeper = featureDistance
        }

        let pixelCount = Int64(asset.pixelWidth) * Int64(asset.pixelHeight)
        self.init(
            bucket: groupContext.bucket,
            groupType: groupContext.groupType,
            confidence: groupContext.confidence,
            suggestedAction: groupContext.suggestedAction,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            isEdited: asset.isEdited,
            isScreenshot: asset.isScreenshot,
            burstPresent: asset.burstIdentifier != nil,
            rankingScore: rankingScore,
            similarityToKeeper: similarityToKeeper,
            aspectRatio: asset.aspectRatio,
            // Candidate generation does not carry encoded bytes. Pixel count is a
            // per-asset estimate rather than the previous constant-zero placeholder.
            fileSizeBytes: max(pixelCount, 1)
        )
    }

    init(asset: PHAsset, group: PhotoGroup) {
        let candidate = group.candidates.first(where: { $0.photoId == asset.localIdentifier })

        self.init(
            bucket: group.reason.rawValue,
            groupType: group.groupType.rawValue,
            confidence: group.groupConfidence.rawValue,
            suggestedAction: group.recommendedAction?.rawValue ?? "reviewManually",
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            isEdited: asset.isEdited,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            burstPresent: asset.burstIdentifier != nil,
            rankingScore: candidate?.bestShotScore ?? 0.5,
            similarityToKeeper: Double(group.similarity),
            aspectRatio: Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1)),
            fileSizeBytes: asset.estimatedFileSize
        )
    }
}

extension GroupActionPredictionInput {
    init(group: PhotoGroup) {
        let screenshotCount = group.assets.filter { $0.mediaSubtypes.contains(.photoScreenshot) }.count
        let favoriteCount = group.assets.filter { $0.isFavorite }.count
        let editedCount = group.assets.filter {
            guard let c = $0.creationDate, let m = $0.modificationDate else { return false }
            return abs(m.timeIntervalSince(c)) > 1
        }.count
        let avgRanking = group.candidates.isEmpty ? 0.5
            : group.candidates.map(\.bestShotScore).reduce(0, +) / Double(group.candidates.count)

        self.init(
            bucket: group.reason.rawValue,
            groupType: group.groupType.rawValue,
            confidence: group.groupConfidence.rawValue,
            suggestedAction: group.recommendedAction?.rawValue ?? "reviewManually",
            assetCount: group.assets.count,
            avgRanking: avgRanking,
            screenshotCount: screenshotCount,
            favoriteCount: favoriteCount,
            editedCount: editedCount
        )
    }
}
