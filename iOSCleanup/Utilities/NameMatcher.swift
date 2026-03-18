import Foundation

struct NameMatcher {
    /// Levenshtein distance between two strings.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                if a[i-1] == b[j-1] {
                    dp[i][j] = dp[i-1][j-1]
                } else {
                    dp[i][j] = 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
                }
            }
        }
        return dp[m][n]
    }

    /// Normalize a full name: lowercase, trim, collapse whitespace.
    private static func normalize(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Reversed name: "John Smith" → "Smith John"
    private static func reversed(_ name: String) -> String {
        let parts = normalize(name).components(separatedBy: " ")
        return parts.reversed().joined(separator: " ")
    }

    /// Minimum Levenshtein distance across both orderings.
    static func distance(_ a: String, _ b: String) -> Int {
        let na = normalize(a), nb = normalize(b)
        let forward = levenshtein(na, nb)
        let rev = levenshtein(reversed(na), nb)
        return min(forward, rev)
    }

    /// Returns true if distance ≤ 2.
    static func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        distance(a, b) <= 2
    }
}
