import XCTest

/// Design-system lint: UI code under `Views/` must use the duck* font tokens,
/// never raw `.font(.system(size:))`, so type stays on the brand scale.
final class DesignLintTests: XCTestCase {
    func testNoRawSystemFontSizesUnderViews() throws {
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
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated()
            where line.contains(".font(.system(size:") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Use duck* font tokens instead of .font(.system(size:)) under Views/ — offenders: \(offenders)"
        )
    }
}
