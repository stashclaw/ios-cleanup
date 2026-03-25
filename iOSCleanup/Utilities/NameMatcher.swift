import Foundation

/// A hardcoded nickname map for common given-name aliases.
/// Lets "Bob" match "Robert", "Bill" match "William", etc.
private let nicknameMap: [String: String] = [
    "bob": "robert",
    "bill": "william",
    "will": "william",
    "billy": "william",
    "rob": "robert",
    "bobby": "robert",
    "rob": "robert",
    "rich": "richard",
    "dick": "richard",
    "rick": "richard",
    "ricky": "richard",
    "mike": "michael",
    "mick": "michael",
    "mickey": "michael",
    "jim": "james",
    "jimmy": "james",
    "jamie": "james",
    "jack": "john",
    "johnny": "john",
    "jon": "john",
    "chris": "christopher",
    "kate": "katherine",
    "kathy": "katherine",
    "cathy": "catherine",
    "cat": "catherine",
    "liz": "elizabeth",
    "beth": "elizabeth",
    "betty": "elizabeth",
    "lisa": "elizabeth",
    "dave": "david",
    "davy": "david",
    "dan": "daniel",
    "danny": "daniel",
    "nick": "nicholas",
    "nicky": "nicholas",
    "pete": "peter",
    "mat": "matthew",
    "matt": "matthew",
    "steve": "steven",
    "steph": "stephanie",
    "sue": "susan",
    "susie": "susan",
    "sam": "samuel",
    "al": "albert",
    "alex": "alexander",
    "tony": "anthony",
    "andy": "andrew",
    "drew": "andrew",
    "jen": "jennifer",
    "jenny": "jennifer",
    "joe": "joseph",
    "joey": "joseph",
    "ben": "benjamin",
    "benny": "benjamin",
    "charlie": "charles",
    "chuck": "charles",
    "tom": "thomas",
    "tommy": "thomas",
    "tim": "timothy",
    "timmy": "timothy",
    "fred": "frederick",
    "freddy": "frederick",
    "frank": "francis",
    "francesca": "frances",
    "fran": "frances",
    "pat": "patricia",
    "pam": "pamela",
    "deb": "deborah",
    "debbie": "deborah",
    "maggie": "margaret",
    "meg": "margaret",
    "peg": "margaret",
    "peggy": "margaret",
    "amy": "amelia",
    "emmy": "emily",
]

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

    /// Normalize a full name: lowercase, trim, fold diacritics, collapse whitespace.
    private static func normalize(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Expand a single token using the nickname map (e.g. "bob" → "robert").
    private static func expandToken(_ token: String) -> String {
        nicknameMap[token] ?? token
    }

    /// Expand all tokens in a name and rejoin.
    private static func expandNicknames(_ name: String) -> String {
        normalize(name)
            .components(separatedBy: " ")
            .map { expandToken($0) }
            .joined(separator: " ")
    }

    /// Reversed name: "John Smith" → "Smith John"
    private static func reversed(_ name: String) -> String {
        let parts = normalize(name).components(separatedBy: " ")
        return parts.reversed().joined(separator: " ")
    }

    /// Minimum Levenshtein distance across both orderings and nickname expansions.
    static func distance(_ a: String, _ b: String) -> Int {
        let na  = normalize(a),         nb  = normalize(b)
        let ena = expandNicknames(a),   enb = expandNicknames(b)
        let candidates = [
            levenshtein(na,  nb),
            levenshtein(reversed(na), nb),
            levenshtein(ena, enb),
            levenshtein(reversed(ena), enb),
        ]
        return candidates.min() ?? 0
    }

    /// Returns true if distance ≤ 2.
    static func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        distance(a, b) <= 2
    }
}
