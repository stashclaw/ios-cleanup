import Foundation

// MARK: - Data model

struct UserDecision: Codable, Sendable {
    let id: UUID
    let recordedAt: Date
    // Pairwise signal — strongest training input
    let keptAssetID: String
    let deletedAssetIDs: [String]
    // Context
    let groupID: UUID
    let similarityReason: String   // "nearDuplicate" | "exactDuplicate" | "visuallySimilar" | "burstShot"
    // Quality labels at decision time (captured BEFORE deletion — critical)
    let keptLabels: [String]
    let deletedLabels: [[String]]
    // Composite scores at decision time
    let keptQualityScore: Float
    let deletedQualityScores: [Float]
    // Feature vectors captured BEFORE deletion — nil for old records (backward compat)
    let featureVector: [Float]?           // kept asset's VNFeaturePrintObservation flattened
    let deletedFeatureVectors: [[Float]]? // each deleted asset's feature vector, parallel to deletedAssetIDs
}

// MARK: - Store

/// Persists keep/delete decisions from GroupReviewView for future MLUpdateTask training.
/// Stores pairwise signals (keptID vs deletedID) + per-asset labels + quality features.
/// All decisions are written to Application Support/userDecisions.json.
actor UserDecisionStore {
    static let shared = UserDecisionStore()
    private init() { load() }

    private static let maxDecisions = 500
    private static let fileName = "userDecisions.json"

    private var decisions: [UserDecision] = []

    // MARK: - Public API

    func record(_ decision: UserDecision) {
        decisions.append(decision)
        // Ring buffer — drop oldest entries when over limit
        if decisions.count > Self.maxDecisions {
            decisions.removeFirst(decisions.count - Self.maxDecisions)
        }
        save()
    }

    func allDecisions() -> [UserDecision] {
        decisions
    }

    func decisionCount() -> Int {
        decisions.count
    }

    func clearAll() {
        decisions = []
        save()
    }

    // MARK: - Persistence

    private func storageURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Self.fileName)
    }

    private func load() {
        guard let url = storageURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([UserDecision].self, from: data) {
            decisions = decoded
        }
    }

    private func save() {
        guard let url = storageURL() else { return }
        // Ensure Application Support directory exists
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? JSONEncoder().encode(decisions) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
