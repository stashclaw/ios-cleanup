import CoreML
import Photos

// MARK: - Protocols

protocol SimilarityClassificationService: Sendable {
    func similarityScore(lhs: PHAsset, rhs: PHAsset) async -> Double?
    var isAvailable: Bool { get }
}

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
    let recommendationAccepted: Int  // -1 = unknown, 0 = false, 1 = true
    let assetCount: Int
    let avgRanking: Double
    let screenshotCount: Int
    let favoriteCount: Int
    let editedCount: Int
}

struct GroupActionPredictionOutput: Sendable {
    let predictedLabel: String       // "keep_best_keeper", "deleted", "skipped", etc.
    let labelProbabilities: [String: Double]
}

// MARK: - Bundled CoreML Similarity Classifier (original, still used for pairwise)

struct BundledCoreMLSimilarityClassifier: SimilarityClassificationService {
    private let modelURL: URL?

    init(modelName: String = "PhotoDuckSimilarity") {
        modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
    }

    var isAvailable: Bool {
        modelURL != nil
    }

    func similarityScore(lhs: PHAsset, rhs: PHAsset) async -> Double? {
        guard modelURL != nil else { return nil }
        return nil
    }
}

// MARK: - ML Keeper Ranking Service

final class MLKeeperRankingService: KeeperPredictionService, @unchecked Sendable {
    static let shared = MLKeeperRankingService()

    private var model: MLModel?
    private let lock = NSLock()
    private var didAttemptLoad = false

    init(modelName: String = "PhotoDuckKeeper") {
        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly // Keep it fast and predictable
            model = try? MLModel(contentsOf: url, configuration: config)
        }
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }

    func predictKeeper(features: KeeperPredictionInput) async -> KeeperPredictionOutput? {
        lock.lock()
        guard let model else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let provider = KeeperFeatureProvider(input: features)
        guard let prediction = try? model.prediction(from: provider) else {
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
}

// MARK: - ML Group Action Service

final class MLGroupActionService: GroupActionPredictionService, @unchecked Sendable {
    static let shared = MLGroupActionService()

    private var model: MLModel?
    private let lock = NSLock()

    init(modelName: String = "PhotoDuckGroupAction") {
        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            model = try? MLModel(contentsOf: url, configuration: config)
        }
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }

    func predictAction(features: GroupActionPredictionInput) async -> GroupActionPredictionOutput? {
        lock.lock()
        guard let model else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let provider = GroupActionFeatureProvider(input: features)
        guard let prediction = try? model.prediction(from: provider) else {
            return nil
        }

        let label = prediction.featureValue(for: "outcome_label")?.stringValue ?? "skipped"
        let probsDict = prediction.featureValue(for: "outcome_labelProbability")?.dictionaryValue as? [String: Double] ?? [:]

        return GroupActionPredictionOutput(
            predictedLabel: label,
            labelProbabilities: probsDict
        )
    }
}

// MARK: - Feature Providers

private class KeeperFeatureProvider: MLFeatureProvider {
    let input: KeeperPredictionInput

    init(input: KeeperPredictionInput) {
        self.input = input
    }

    var featureNames: Set<String> {
        Set([
            "bucket", "group_type", "confidence", "suggested_action",
            "pixel_width", "pixel_height", "is_favorite", "is_edited",
            "is_screenshot", "burst_present", "ranking_score",
            "similarity_to_keeper", "aspect_ratio", "file_size_bytes"
        ])
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

private class GroupActionFeatureProvider: MLFeatureProvider {
    let input: GroupActionPredictionInput

    init(input: GroupActionPredictionInput) {
        self.input = input
    }

    var featureNames: Set<String> {
        Set([
            "bucket", "group_type", "confidence", "suggested_action",
            "recommendation_accepted", "asset_count", "avg_ranking",
            "screenshot_count", "favorite_count", "edited_count"
        ])
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "bucket": return MLFeatureValue(string: input.bucket)
        case "group_type": return MLFeatureValue(string: input.groupType)
        case "confidence": return MLFeatureValue(string: input.confidence)
        case "suggested_action": return MLFeatureValue(string: input.suggestedAction)
        case "recommendation_accepted": return MLFeatureValue(int64: Int64(input.recommendationAccepted))
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

extension KeeperPredictionInput {
    init(asset: PHAsset, group: PhotoGroup) {
        let isEdited: Bool
        if let creationDate = asset.creationDate, let modificationDate = asset.modificationDate {
            isEdited = abs(modificationDate.timeIntervalSince(creationDate)) > 1
        } else {
            isEdited = false
        }

        let candidate = group.candidates.first(where: { $0.photoId == asset.localIdentifier })

        self.init(
            bucket: group.reason.rawValue,
            groupType: group.groupType.rawValue,
            confidence: group.groupConfidence.rawValue,
            suggestedAction: group.recommendedAction?.rawValue ?? "reviewManually",
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            isEdited: isEdited,
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
            recommendationAccepted: -1,
            assetCount: group.assets.count,
            avgRanking: avgRanking,
            screenshotCount: screenshotCount,
            favoriteCount: favoriteCount,
            editedCount: editedCount
        )
    }
}
