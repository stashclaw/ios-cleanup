import CoreML
import Photos

protocol SimilarityClassificationService: Sendable {
    func similarityScore(lhs: PHAsset, rhs: PHAsset) async -> Double?
    var isAvailable: Bool { get }
}

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
        // The app currently falls back to heuristics. This hook lets us plug in a
        // bundled CoreML model later without changing the surrounding architecture.
        return nil
    }
}
