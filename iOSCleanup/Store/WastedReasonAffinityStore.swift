import Foundation

/// Tracks how many times the user has explicitly deleted photos of each WastedReason
/// category from Smart Picks. Used to prioritize high-affinity categories in future scans:
/// categories deleted ≥3 times surface above quality picks; ≥5 times expand scan cap 2×.
actor WastedReasonAffinityStore {
    static let shared = WastedReasonAffinityStore()
    private init() {}

    private let udKey = "wastedReasonDeletionCounts"

    // MARK: - Public API

    /// Increment the deletion count for a reason (call on every Smart Picks delete).
    func recordDeletion(reason: WastedReason) {
        var counts = loadCounts()
        counts[reason.rawValue, default: 0] += 1
        saveCounts(counts)
    }

    /// Returns the deletion count for a single reason.
    func deletionCount(for reason: WastedReason) -> Int {
        loadCounts()[reason.rawValue] ?? 0
    }

    /// Returns all deletion counts keyed by WastedReason (omits reasons with zero deletes).
    func allCounts() -> [WastedReason: Int] {
        let raw = loadCounts()
        var result: [WastedReason: Int] = [:]
        for (key, count) in raw {
            if let reason = WastedReason(rawValue: key) {
                result[reason] = count
            }
        }
        return result
    }

    /// True when any category has been deleted enough to trigger expanded scanning.
    func hasHighAffinityCategory(threshold: Int = 5) -> Bool {
        loadCounts().values.contains { $0 >= threshold }
    }

    // MARK: - Persistence

    private func loadCounts() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: udKey) as? [String: Int] ?? [:]
    }

    private func saveCounts(_ counts: [String: Int]) {
        UserDefaults.standard.set(counts, forKey: udKey)
    }
}
