import CoreML
import Foundation
import Photos
import UIKit

// MARK: - MLModelUpdater

/// Runs MLUpdateTask to fine-tune the bundled PhotoQualityClassifier on the user's own
/// keep/delete decisions captured by GroupReviewViewModel + UserDecisionStore.
///
/// Training approach:
///   For each UserDecision, the *kept* asset image is fetched at 224×224 from PHImageManager
///   and added as a "kept" training example. Deleted assets cannot be refetched (they have been
///   removed from the library), so the training set is kept-positive-only. The model learns
///   "what good photos look like for this user" rather than a symmetric binary classifier.
///
/// Requirements:
///   - PhotoQualityClassifier.mlmodelc must be bundled AND compiled with isUpdatable = true.
///   - At least 50 decisions with stored featureVector must exist in UserDecisionStore.
///
/// Output:
///   Application Support/PhotoQualityClassifier_personalized.mlmodelc
///   PhotoQualityAnalyzer checks this path first and falls back to the bundle model if absent.
actor MLModelUpdater {

    static let shared = MLModelUpdater()
    private init() {}

    // MARK: - Constants

    private static let minimumDecisions = 50
    private static let personalizedModelName = "PhotoQualityClassifier_personalized.mlmodelc"
    private static let bundleModelName = "PhotoQualityClassifier"

    // MARK: - Public API

    /// Check whether enough decisions have accumulated and, if so, run MLUpdateTask.
    /// Safe to call multiple times — the underlying work is non-reentrant by virtue of the
    /// actor's serial execution. Call from a background context (e.g., BGProcessingTask).
    func updateIfReady() async {
        let decisions = await UserDecisionStore.shared.allDecisions()

        // Only decisions with stored feature vectors are usable (backward compat guard).
        let usable = decisions.filter { $0.featureVector != nil }
        guard usable.count >= Self.minimumDecisions else { return }

        do {
            try await runUpdate(decisions: usable)
            NotificationCenter.default.post(
                name: Notification.Name("mlModelDidUpdate"),
                object: nil
            )
        } catch {
            // Non-fatal — model may not be updatable (e.g., trained without isUpdatable = true).
            // PhotoQualityAnalyzer continues with the bundle model or heuristics.
        }
    }

    /// Returns true when a personalized model has been written to Application Support.
    func hasPersonalizedModel() -> Bool {
        guard let url = personalizedModelURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The number of decisions currently stored (for diagnostics / Settings UI).
    func decisionCount() async -> Int {
        await UserDecisionStore.shared.decisionCount()
    }

    // MARK: - Core pipeline

    private func runUpdate(decisions: [UserDecision]) async throws {
        // 1. Locate the updatable bundle model
        guard let bundleURL = Bundle.main.url(
            forResource: Self.bundleModelName,
            withExtension: "mlmodelc"
        ) else {
            // Model not bundled — skip silently
            return
        }

        // 2. Build training batch (image + label pairs)
        guard let batchProvider = buildBatchProvider(from: decisions),
              batchProvider.count > 0 else { return }

        // 3. Determine output URL
        guard let outputURL = personalizedModelURL() else { return }

        // 4. Ensure Application Support directory exists
        let dir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 5. Run MLUpdateTask (bridged to async/await via continuation)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let task = try MLUpdateTask(
                    forModelAt: bundleURL,
                    trainingData: batchProvider,
                    configuration: config,
                    completionHandler: { context in
                        if let error = context.task.error {
                            continuation.resume(throwing: error)
                            return
                        }
                        do {
                            // Persist the fine-tuned model to Application Support
                            try context.model.write(to: outputURL)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                )
                task.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Batch provider construction

    /// Builds an MLArrayBatchProvider from kept-asset images.
    ///
    /// Feature names must match the model's input spec:
    ///   "image"      — CVPixelBuffer, 224×224, ARGB
    ///   "classLabel" — String label ("kept" / "deleted")
    ///
    /// Deleted assets cannot be refetched after PHPhotoLibrary.performChanges deletes them,
    /// so only the kept side provides positive training examples. This is sufficient because
    /// the model learns "what this user keeps" — the complement is implicit.
    private func buildBatchProvider(from decisions: [UserDecision]) -> MLBatchProvider? {
        var providers: [MLFeatureProvider] = []

        for decision in decisions {
            guard let image = fetchImageSync(assetID: decision.keptAssetID, size: 224),
                  let pixelBuffer = image.toCVPixelBuffer(size: CGSize(width: 224, height: 224))
            else {
                // Asset may have been deleted manually since the decision was recorded — skip
                continue
            }
            providers.append(
                PhotoQualityFeatureProvider(pixelBuffer: pixelBuffer, label: "kept")
            )
        }

        guard !providers.isEmpty else { return nil }
        return try? MLArrayBatchProvider(array: providers)
    }

    // MARK: - Synchronous image fetch

    /// Fetches a square thumbnail of a PHAsset synchronously using a semaphore.
    /// Must be called from a non-main background context (BGProcessingTask satisfies this).
    private func fetchImageSync(assetID: String, size: Int) -> UIImage? {
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: nil
        )
        guard let asset = fetchResult.firstObject else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var fetchedImage: UIImage?

        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = false
        opts.isSynchronous = false

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: size, height: size),
            contentMode: .aspectFill,
            options: opts
        ) { image, info in
            // Skip the low-resolution degraded delivery delivered first on some async requests
            if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
            fetchedImage = image
            semaphore.signal()
        }

        semaphore.wait()
        return fetchedImage
    }

    // MARK: - Helpers

    private func personalizedModelURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Self.personalizedModelName)
    }
}

// MARK: - MLFeatureProvider

/// Wraps a single 224×224 pixel buffer + class label string as one MLUpdateTask training row.
/// Feature names must exactly match the Create ML model's declared input/output spec.
private final class PhotoQualityFeatureProvider: NSObject, MLFeatureProvider {

    let pixelBuffer: CVPixelBuffer
    let label: String

    var featureNames: Set<String> { ["image", "classLabel"] }

    init(pixelBuffer: CVPixelBuffer, label: String) {
        self.pixelBuffer = pixelBuffer
        self.label = label
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "image":
            return MLFeatureValue(pixelBuffer: pixelBuffer)
        case "classLabel":
            return MLFeatureValue(string: label)
        default:
            return nil
        }
    }
}

// MARK: - UIImage → CVPixelBuffer

private extension UIImage {
    /// Renders the image into a 32-bit ARGB CVPixelBuffer at the given size.
    func toCVPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey:       true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        // Core Graphics origin is bottom-left; flip to match UIKit's top-left convention
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(context)
        draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()

        return pb
    }
}
