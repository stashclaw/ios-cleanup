#!/usr/bin/env swift
//
// TrainKeeperModel.swift
// PhotoDuck ML Training Pipeline
//
// Run on Mac to train keeper ranking + group action models from exported data.
//
// Usage:
//   swift TrainKeeperModel.swift <path-to-exported-sqlite-or-csv-dir>
//
// Outputs:
//   PhotoDuckKeeper.mlmodel    — keeper ranking classifier
//   PhotoDuckGroupAction.mlmodel — group action classifier
//
// These get compiled via:
//   xcrun coremlcompiler compile PhotoDuckKeeper.mlmodel .
//   xcrun coremlcompiler compile PhotoDuckGroupAction.mlmodel .
//
// Then bundle the .mlmodelc directories into the app.

import Foundation
import CreateML
import TabularData

// MARK: - Configuration

struct TrainingConfig {
    let minRowsForTraining = 20
    let testSplitRatio = 0.2
    let maxIterations = 100
    let maxDepth = 6
    let randomSeed = 42
}

let config = TrainingConfig()

// MARK: - Entry Point

func main() throws {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        print("Usage: swift TrainKeeperModel.swift <path-to-export-dir>")
        print("")
        print("The export directory should contain:")
        print("  - keeper_ranking_training.csv")
        print("  - group_outcome_training.csv")
        print("  OR")
        print("  - photoduck-ml.sqlite")
        exit(1)
    }

    let exportPath = args[1]
    let exportURL = URL(fileURLWithPath: exportPath)

    // Check for CSV files first
    let keeperCSVURL = exportURL.appendingPathComponent("keeper_ranking_training.csv")
    let groupCSVURL = exportURL.appendingPathComponent("group_outcome_training.csv")

    let outputDir = exportURL.appendingPathComponent("trained-models", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

    print("PhotoDuck ML Training Pipeline")
    print("==============================")
    print("Export dir: \(exportPath)")
    print("Output dir: \(outputDir.path)")
    print("")

    // Train keeper ranking model
    if FileManager.default.fileExists(atPath: keeperCSVURL.path) {
        try trainKeeperModel(csvURL: keeperCSVURL, outputDir: outputDir)
    } else {
        print("⚠ No keeper_ranking_training.csv found, skipping keeper model")
    }

    print("")

    // Train group action model
    if FileManager.default.fileExists(atPath: groupCSVURL.path) {
        try trainGroupActionModel(csvURL: groupCSVURL, outputDir: outputDir)
    } else {
        print("⚠ No group_outcome_training.csv found, skipping group action model")
    }

    print("")
    print("Done! Models saved to: \(outputDir.path)")
    print("")
    print("To compile for iOS:")
    print("  xcrun coremlcompiler compile \(outputDir.path)/PhotoDuckKeeper.mlmodel .")
    print("  xcrun coremlcompiler compile \(outputDir.path)/PhotoDuckGroupAction.mlmodel .")
}

// MARK: - Keeper Ranking Model

func trainKeeperModel(csvURL: URL, outputDir: URL) throws {
    print("--- Keeper Ranking Model ---")

    let csvString = try String(contentsOf: csvURL, encoding: .utf8)
    let dataFrame = try DataFrame(csvData: csvString.data(using: .utf8)!)

    print("Loaded \(dataFrame.rows.count) keeper ranking rows")

    guard dataFrame.rows.count >= config.minRowsForTraining else {
        print("⚠ Not enough data (\(dataFrame.rows.count) < \(config.minRowsForTraining)), skipping")
        return
    }

    // Feature columns
    let featureColumns = [
        "bucket", "group_type", "confidence", "suggested_action",
        "pixel_width", "pixel_height", "is_favorite", "is_edited",
        "is_screenshot", "burst_present", "ranking_score",
        "similarity_to_keeper", "aspect_ratio", "file_size_bytes"
    ]

    let targetColumn = "outcome_label"

    // Filter to columns that exist
    let existingColumns = Set(dataFrame.columns.map(\.name))
    let validFeatures = featureColumns.filter { existingColumns.contains($0) }

    print("Using features: \(validFeatures.joined(separator: ", "))")
    print("Target: \(targetColumn)")

    // Split data
    let (trainingData, testingData) = dataFrame.randomSplit(
        by: config.testSplitRatio,
        seed: config.randomSeed
    )

    print("Training: \(trainingData.rows.count) rows, Testing: \(testingData.rows.count) rows")

    // Train boosted tree classifier
    let classifier = try MLBoostedTreeClassifier(
        trainingData: DataFrame(trainingData),
        targetColumn: targetColumn,
        featureColumns: validFeatures,
        parameters: .init(
            validation: .split(strategy: .automatic),
            maxIterations: config.maxIterations,
            maxDepth: config.maxDepth,
            randomSeed: config.randomSeed
        )
    )

    // Evaluate
    let trainingMetrics = classifier.trainingMetrics
    let validationMetrics = classifier.validationMetrics
    print("Training accuracy:   \(String(format: "%.2f%%", (trainingMetrics.classificationError) * 100))")
    print("Validation accuracy: \(String(format: "%.2f%%", (validationMetrics.classificationError) * 100))")

    let testMetrics = classifier.evaluation(on: DataFrame(testingData), targetColumn: targetColumn)
    print("Test accuracy:       \(String(format: "%.2f%%", (testMetrics.classificationError) * 100))")

    // Save model
    let metadata = MLModelMetadata(
        author: "PhotoDuck ML Pipeline",
        shortDescription: "Predicts which photo the user will keep as the best in a similar group",
        version: "1.0"
    )

    let modelURL = outputDir.appendingPathComponent("PhotoDuckKeeper.mlmodel")
    try classifier.write(to: modelURL, metadata: metadata)
    print("Saved: \(modelURL.path)")

    // Also export feature importance
    let importanceURL = outputDir.appendingPathComponent("keeper_feature_importance.json")
    let importance = validFeatures.map { feature -> [String: Any] in
        // Feature importance not directly available from MLBoostedTreeClassifier,
        // so we record feature names for reference
        return ["feature": feature]
    }
    let importanceData = try JSONSerialization.data(withJSONObject: importance, options: .prettyPrinted)
    try importanceData.write(to: importanceURL)
}

// MARK: - Group Action Model

func trainGroupActionModel(csvURL: URL, outputDir: URL) throws {
    print("--- Group Action Model ---")

    let csvString = try String(contentsOf: csvURL, encoding: .utf8)
    let dataFrame = try DataFrame(csvData: csvString.data(using: .utf8)!)

    print("Loaded \(dataFrame.rows.count) group outcome rows")

    guard dataFrame.rows.count >= config.minRowsForTraining else {
        print("⚠ Not enough data (\(dataFrame.rows.count) < \(config.minRowsForTraining)), skipping")
        return
    }

    let featureColumns = [
        "bucket", "group_type", "confidence", "suggested_action",
        "recommendation_accepted", "asset_count", "avg_ranking",
        "screenshot_count", "favorite_count", "edited_count"
    ]

    let targetColumn = "outcome_label"

    let existingColumns = Set(dataFrame.columns.map(\.name))
    let validFeatures = featureColumns.filter { existingColumns.contains($0) }

    print("Using features: \(validFeatures.joined(separator: ", "))")
    print("Target: \(targetColumn)")

    let (trainingData, testingData) = dataFrame.randomSplit(
        by: config.testSplitRatio,
        seed: config.randomSeed
    )

    print("Training: \(trainingData.rows.count) rows, Testing: \(testingData.rows.count) rows")

    let classifier = try MLBoostedTreeClassifier(
        trainingData: DataFrame(trainingData),
        targetColumn: targetColumn,
        featureColumns: validFeatures,
        parameters: .init(
            validation: .split(strategy: .automatic),
            maxIterations: config.maxIterations,
            maxDepth: config.maxDepth,
            randomSeed: config.randomSeed
        )
    )

    let trainingMetrics = classifier.trainingMetrics
    let validationMetrics = classifier.validationMetrics
    print("Training accuracy:   \(String(format: "%.2f%%", (trainingMetrics.classificationError) * 100))")
    print("Validation accuracy: \(String(format: "%.2f%%", (validationMetrics.classificationError) * 100))")

    let testMetrics = classifier.evaluation(on: DataFrame(testingData), targetColumn: targetColumn)
    print("Test accuracy:       \(String(format: "%.2f%%", (testMetrics.classificationError) * 100))")

    let metadata = MLModelMetadata(
        author: "PhotoDuck ML Pipeline",
        shortDescription: "Predicts what action the user will take on a group of similar photos",
        version: "1.0"
    )

    let modelURL = outputDir.appendingPathComponent("PhotoDuckGroupAction.mlmodel")
    try classifier.write(to: modelURL, metadata: metadata)
    print("Saved: \(modelURL.path)")
}

// MARK: - Run

do {
    try main()
} catch {
    print("Error: \(error)")
    exit(1)
}
