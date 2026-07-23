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
    let minimumFeatureSchemaVersion = 2

    var trainingSplitRatio: Double { 1 - testSplitRatio }
}

let config = TrainingConfig()

enum TrainingDataError: LocalizedError {
    case missingActiveChoiceSignal
    case missingGroupIdentifier
    case insufficientGroups(Int)
    case invalidSplit(trainingRows: Int, testingRows: Int, totalRows: Int)
    case outdatedFeatureSchema(Int)

    var errorDescription: String? {
        switch self {
        case .missingActiveChoiceSignal:
            return "Keeper training requires active_choice (or legacy recommendation_accepted) so accepted defaults can be excluded."
        case .missingGroupIdentifier:
            return "Training CSV requires event_id or group_id for a leakage-safe group split."
        case .insufficientGroups(let count):
            return "Training requires at least two distinct feedback groups; found \(count)."
        case .invalidSplit(let trainingRows, let testingRows, let totalRows):
            return "Invalid group split: \(trainingRows) training + \(testingRows) testing != \(totalRows) total."
        case .outdatedFeatureSchema(let version):
            return "Feature schema \(version) is older than required schema \(config.minimumFeatureSchemaVersion)."
        }
    }
}

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
    let rawDataFrame = try DataFrame(csvData: csvString.data(using: .utf8)!)
    let dataFrame = try activeKeeperChoices(from: rawDataFrame)

    print("Loaded \(rawDataFrame.rows.count) keeper ranking rows")
    print("Active-choice rows: \(dataFrame.rows.count)")

    guard dataFrame.rows.count >= config.minRowsForTraining else {
        print("⚠ Not enough data (\(dataFrame.rows.count) < \(config.minRowsForTraining)), skipping")
        return
    }

    try validateFeatureSchema(in: dataFrame)

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

    // Split entire review events together so sibling candidates cannot leak
    // across training and testing sets.
    let (trainingData, testingData) = try groupAwareSplit(dataFrame)

    print("Training: \(trainingData.rows.count) rows, Testing: \(testingData.rows.count) rows")

    // Train boosted tree classifier
    let classifier = try MLBoostedTreeClassifier(
        trainingData: trainingData,
        targetColumn: targetColumn,
        featureColumns: validFeatures,
        parameters: .init(
            validation: .split(strategy: .automatic),
            maxDepth: config.maxDepth,
            maxIterations: config.maxIterations,
            randomSeed: config.randomSeed
        )
    )

    // Evaluate
    let trainingMetrics = classifier.trainingMetrics
    let validationMetrics = classifier.validationMetrics
    print("Training accuracy:   \(formattedAccuracy(classificationError: trainingMetrics.classificationError))")
    print("Validation accuracy: \(formattedAccuracy(classificationError: validationMetrics.classificationError))")

    let testMetrics = classifier.evaluation(on: testingData)
    print("Test accuracy:       \(formattedAccuracy(classificationError: testMetrics.classificationError))")

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
    var dataFrame = try DataFrame(csvData: csvString.data(using: .utf8)!)

    // This value is calculated from the same user decision as the target label.
    // Remove it before feature discovery so it cannot re-enter training.
    if dataFrame.indexOfColumn("recommendation_accepted") != nil {
        dataFrame.removeColumn("recommendation_accepted")
    }

    print("Loaded \(dataFrame.rows.count) group outcome rows")

    guard dataFrame.rows.count >= config.minRowsForTraining else {
        print("⚠ Not enough data (\(dataFrame.rows.count) < \(config.minRowsForTraining)), skipping")
        return
    }

    let featureColumns = [
        "bucket", "group_type", "confidence", "suggested_action",
        "asset_count", "avg_ranking", "screenshot_count", "favorite_count",
        "edited_count"
    ]

    let targetColumn = "outcome_label"

    let existingColumns = Set(dataFrame.columns.map(\.name))
    let validFeatures = featureColumns.filter { existingColumns.contains($0) }

    print("Using features: \(validFeatures.joined(separator: ", "))")
    print("Target: \(targetColumn)")

    let (trainingData, testingData) = try groupAwareSplit(dataFrame)

    print("Training: \(trainingData.rows.count) rows, Testing: \(testingData.rows.count) rows")

    let classifier = try MLBoostedTreeClassifier(
        trainingData: trainingData,
        targetColumn: targetColumn,
        featureColumns: validFeatures,
        parameters: .init(
            validation: .split(strategy: .automatic),
            maxDepth: config.maxDepth,
            maxIterations: config.maxIterations,
            randomSeed: config.randomSeed
        )
    )

    let trainingMetrics = classifier.trainingMetrics
    let validationMetrics = classifier.validationMetrics
    print("Training accuracy:   \(formattedAccuracy(classificationError: trainingMetrics.classificationError))")
    print("Validation accuracy: \(formattedAccuracy(classificationError: validationMetrics.classificationError))")

    let testMetrics = classifier.evaluation(on: testingData)
    print("Test accuracy:       \(formattedAccuracy(classificationError: testMetrics.classificationError))")

    let metadata = MLModelMetadata(
        author: "PhotoDuck ML Pipeline",
        shortDescription: "Predicts what action the user will take on a group of similar photos",
        version: "1.0"
    )

    let modelURL = outputDir.appendingPathComponent("PhotoDuckGroupAction.mlmodel")
    try classifier.write(to: modelURL, metadata: metadata)
    print("Saved: \(modelURL.path)")
}

// MARK: - Training Integrity

func activeKeeperChoices(from source: DataFrame) throws -> DataFrame {
    var dataFrame = source
    let values: [Bool?]

    if dataFrame.indexOfColumn("active_choice") != nil {
        values = dataFrame.rows.map { row in
            boolValue(row["active_choice"])
        }
        dataFrame.removeColumn("active_choice")
    } else {
        guard dataFrame.indexOfColumn("recommendation_accepted") != nil else {
            throw TrainingDataError.missingActiveChoiceSignal
        }

        // Legacy schema compatibility: a rejected keeper recommendation means
        // the final keeper differs from the suggestion. Unknown values remain
        // ineligible rather than being guessed into the training set.
        values = dataFrame.rows.map { row in
            guard let accepted = boolValue(row["recommendation_accepted"]) else {
                return nil
            }
            return !accepted
        }
    }
    dataFrame.append(column: Column<Bool>(name: "active_choice", contents: values))

    let activeRows = dataFrame.filter(on: "active_choice", Bool.self) { value in
        value == true
    }
    return DataFrame(activeRows)
}

func validateFeatureSchema(in dataFrame: DataFrame) throws {
    guard dataFrame.indexOfColumn("feature_schema_version") != nil else {
        print("⚠ No feature_schema_version column; treating this as a legacy export")
        return
    }

    for row in dataFrame.rows {
        guard let version = intValue(row["feature_schema_version"]) else {
            continue
        }
        guard version >= config.minimumFeatureSchemaVersion else {
            throw TrainingDataError.outdatedFeatureSchema(version)
        }
    }
}

func groupAwareSplit(_ dataFrame: DataFrame) throws -> (DataFrame, DataFrame) {
    let groupColumn = ["event_id", "group_id"].first {
        dataFrame.indexOfColumn($0) != nil
    }
    guard let groupColumn else {
        throw TrainingDataError.missingGroupIdentifier
    }

    let groupedRows = dataFrame.grouped(by: groupColumn)
    guard groupedRows.count >= 2 else {
        throw TrainingDataError.insufficientGroups(groupedRows.count)
    }

    let (trainingGroups, testingGroups) = groupedRows.randomSplit(
        by: config.trainingSplitRatio,
        seed: config.randomSeed
    )
    let trainingData = trainingGroups.ungrouped()
    let testingData = testingGroups.ungrouped()
    let splitCount = trainingData.rows.count + testingData.rows.count

    guard !trainingData.rows.isEmpty,
          !testingData.rows.isEmpty,
          splitCount == dataFrame.rows.count else {
        throw TrainingDataError.invalidSplit(
            trainingRows: trainingData.rows.count,
            testingRows: testingData.rows.count,
            totalRows: dataFrame.rows.count
        )
    }

    assert(
        splitCount == dataFrame.rows.count,
        "Group-aware split must preserve every training row exactly once."
    )
    assert(
        trainingGroups.count + testingGroups.count == groupedRows.count,
        "Group-aware split must preserve every review group exactly once."
    )
    return (trainingData, testingData)
}

func formattedAccuracy(classificationError: Double) -> String {
    let accuracy = max(0, min(1, 1 - classificationError))
    return String(format: "%.2f%%", accuracy * 100)
}

func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
        return value
    case let value as Int:
        guard value == 0 || value == 1 else { return nil }
        return value == 1
    case let value as Int32:
        guard value == 0 || value == 1 else { return nil }
        return value == 1
    case let value as Int64:
        guard value == 0 || value == 1 else { return nil }
        return value == 1
    case let value as Double:
        guard value == 0 || value == 1 else { return nil }
        return value == 1
    case let value as String:
        switch value.lowercased() {
        case "true", "1":
            return true
        case "false", "0":
            return false
        default:
            return nil
        }
    default:
        return nil
    }
}

func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
        return value
    case let value as Int32:
        return Int(value)
    case let value as Int64:
        return Int(value)
    case let value as Double:
        return Int(exactly: value)
    case let value as String:
        return Int(value)
    default:
        return nil
    }
}

// MARK: - Run

do {
    try main()
} catch {
    print("Error: \(error)")
    exit(1)
}
