import XCTest

/// Design-system lint: UI code under `Views/` must use the duck* font tokens.
/// Two rules are enforced:
///   1. no raw `.font(.system(size:))`
///   2. no bare SwiftUI text styles (`.font(.headline)`, `.font(.title2)`, …)
/// Rule 2 exists because rule 1 alone only caught explicit point sizes, so raw
/// `.headline` / `.title2` / `.largeTitle` / `.body` usages slipped through.
final class DesignLintTests: XCTestCase {

    /// TEMPORARY allowlist for rule 2, keyed by file name.
    ///
    /// These files still contain bare SwiftUI text styles and are being
    /// migrated to duck* tokens in a separate, concurrent change. Delete each
    /// entry as soon as its file is clean — the lint is only meaningful once
    /// this dictionary is empty. Do not add new entries.
    /// Intentionally empty: every view now uses duck* tokens. Adding a file
    /// here silently exempts it, so prefer fixing the offender.
    private static let bareTextStyleAllowlist: Set<String> = []

    /// Bare SwiftUI text styles that must be replaced with duck* tokens.
    /// The pattern also matches `.weight(...)` / `.bold()` variants, e.g.
    /// `.font(.body.weight(.semibold))`, because the trailing `\b` only
    /// anchors the end of the style name.
    private static let bareTextStyles = [
        "largeTitle", "title3", "title2", "title",
        "headline", "subheadline",
        "body", "callout", "footnote",
        "caption2", "caption"
    ]

    // MARK: - Rule 1

    func testNoRawSystemFontSizesUnderViews() throws {
        let offenders = try scanViews { line in
            line.contains(".font(.system(size:")
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Use duck* font tokens instead of .font(.system(size:)) under Views/ — offenders: \(offenders)"
        )
    }

    // MARK: - Rule 2

    func testNoBareSwiftUITextStylesUnderViews() throws {
        let pattern = "\\.font\\(\\.(?:" + Self.bareTextStyles.joined(separator: "|") + ")\\b"
        let regex = try NSRegularExpression(pattern: pattern)

        let offenders = try scanViews(skipping: Self.bareTextStyleAllowlist) { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return regex.firstMatch(in: line, range: range) != nil
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Use duck* font tokens instead of bare SwiftUI text styles under Views/ \
            (.headline, .subheadline, .caption, .caption2, .title, .title2, .title3, \
            .largeTitle, .body, .footnote and their .weight(…)/.bold() variants) \
            — offenders: \(offenders)
            """
        )
    }

    // MARK: - Helpers

    /// Walks every Swift file under `iOSCleanup/Views` and returns
    /// `"File.swift:<line>"` for each line the predicate flags.
    private func scanViews(
        skipping allowlist: Set<String> = [],
        where isOffending: (String) -> Bool
    ) throws -> [String] {
        let viewsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // iOSCleanupTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("iOSCleanup/Views")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: viewsDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("Views sources not available in this test environment")
        }

        let enumerator = FileManager.default.enumerator(at: viewsDir, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard !allowlist.contains(url.lastPathComponent) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated()
            where isOffending(line) {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        return offenders
    }
}
