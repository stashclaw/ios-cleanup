#!/usr/bin/env swift

// TrainPhotoQualityClassifier.swift
// Run: swift TrainPhotoQualityClassifier.swift
// Requires macOS 12+ with Xcode installed.
//
// Dataset structure expected at ./TrainingData/:
//   TrainingData/
//     sharp/        ← 500+ sharp, well-exposed, in-focus photos
//     blurry/       ← 500+ blurry, out-of-focus, motion-blurred photos
//     overexposed/  ← 200+ blown-out, white-sky photos
//     underexposed/ ← 200+ dark, underexposed photos
//
// Output: PhotoQualityClassifier.mlmodel (copy into iOSCleanup/Resources/)

import CreateML
import Foundation

// MARK: - Paths

let scriptDir   = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let trainingURL = scriptDir.appendingPathComponent("TrainingData")
let outputURL   = scriptDir.appendingPathComponent("PhotoQualityClassifier.mlmodel")

// MARK: - Validation

func validateDataset() throws {
    let fm = FileManager.default
    let required = ["sharp", "blurry", "overexposed", "underexposed"]
    var missing: [String] = []
    var totals: [String: Int] = [:]

    for folder in required {
        let dir = trainingURL.appendingPathComponent(folder)
        guard fm.fileExists(atPath: dir.path) else {
            missing.append(folder)
            continue
        }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let imageCount = contents.filter { f in
            let ext = (f as NSString).pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "heic", "tiff"].contains(ext)
        }.count
        totals[folder] = imageCount
        print("  \(folder)/: \(imageCount) images")
    }

    if !missing.isEmpty {
        throw ValidationError.missingFolders(missing)
    }

    let tooFew = totals.filter { folder, count in
        let minimum = (folder == "sharp" || folder == "blurry") ? 500 : 200
        return count < minimum
    }
    if !tooFew.isEmpty {
        print("⚠️  Warning: some folders have fewer images than recommended:")
        for (folder, count) in tooFew {
            let minimum = (folder == "sharp" || folder == "blurry") ? 500 : 200
            print("     \(folder)/: \(count) images (recommended ≥ \(minimum))")
        }
        print("   Training will proceed but accuracy may be lower.")
    }
}

enum ValidationError: Error, CustomStringConvertible {
    case missingFolders([String])
    var description: String {
        switch self {
        case .missingFolders(let f):
            return "Missing required folders in TrainingData/: \(f.joined(separator: ", "))\n" +
                   "See README.md for dataset setup instructions."
        }
    }
}

// MARK: - Main

print("PhotoDuck — Photo Quality Classifier Training")
print("==============================================")
print("Training data: \(trainingURL.path)")
print("Output:        \(outputURL.path)")
print("")

// Validate dataset layout
print("Checking dataset layout...")
do {
    try validateDataset()
} catch {
    print("Error: \(error)")
    exit(1)
}
print("")

// Train
print("Starting training (this takes 20–40 minutes on Apple Silicon)...")
print("Augmentations: flip, rotate, blur, exposure, noise")
print("")

do {
    // MLImageClassifier.ModelParameters controls augmentation and iterations.
    // 25 iterations is a reasonable balance between speed and accuracy for a
    // 4-class dataset of ~1400 images. Increase to 50 if validation accuracy
    // stalls above 88%.
    var params = MLImageClassifier.ModelParameters()
    params.validationData = .split(strategy: .automatic)   // 20% auto-split
    params.maxIterations  = 25
    params.augmentationOptions = [
        .flip,
        .rotate,
        .blur,
        .exposure,
        .noise,
    ]
    // isUpdatable = true compiles the model with an MLUpdateTask-compatible training graph,
    // enabling on-device fine-tuning via MLModelUpdater without retraining from scratch.
    // Required for PhotoDuck's personalisation flywheel (Phase 5).
    params.isUpdatable = true

    let classifier = try MLImageClassifier(
        trainingData: .labeledDirectories(at: trainingURL),
        parameters: params
    )

    // Report metrics
    let trainingMetrics   = classifier.trainingMetrics
    let validationMetrics = classifier.validationMetrics

    let trainAcc = (1.0 - trainingMetrics.classificationError) * 100
    let valAcc   = (1.0 - validationMetrics.classificationError) * 100

    print("")
    print("Training complete:")
    print("  Training accuracy:   \(String(format: "%.1f", trainAcc))%")
    print("  Validation accuracy: \(String(format: "%.1f", valAcc))%")

    if valAcc < 75 {
        print("")
        print("⚠️  Validation accuracy is below 75%.")
        print("   Consider:")
        print("   • Adding more images to the underrepresented classes")
        print("   • Increasing maxIterations to 50")
        print("   • Reviewing your dataset for mislabelled images")
    }

    // Save
    let metadata = MLModelMetadata(
        author: "PhotoDuck",
        shortDescription: "Classifies photos as sharp, blurry, overexposed, or underexposed. " +
                          "Used by PhotoQualityAnalyzer to rank photos within duplicate groups.",
        version: "1.0"
    )
    try classifier.write(to: outputURL, metadata: metadata)

    print("")
    print("Model saved to: \(outputURL.path)")
    print("")
    print("Next steps:")
    print("  1. Copy PhotoQualityClassifier.mlmodel into iOSCleanup/Resources/")
    print("  2. In Xcode: drag into the Resources group, check 'Add to target: iOSCleanup'")
    print("  3. Build — the app will automatically pick up the model via PhotoQualityAnalyzer")
    print("")
    print("If the model is not present at runtime, PhotoQualityAnalyzer falls back")
    print("to the existing heuristic pipeline (Laplacian blur + luminance + Vision face).")

} catch {
    print("Training failed: \(error)")
    exit(1)
}
