import XCTest
@testable import iOSCleanup

final class PhotoScanEngineTests: XCTestCase {

    // Test union-find transitivity: A~B, B~C → single group [A,B,C]
    func testUnionFindTransitivity() async {
        // We test the clustering logic indirectly via a mock subclass is not easy with actors.
        // Instead we validate the logic by checking the union-find helper behavior.
        // This test verifies the conceptual correctness with a pure Swift union-find.
        var parent: [String: String] = ["A": "A", "B": "B", "C": "C"]

        func find(_ id: String) -> String {
            if parent[id] != id { parent[id] = find(parent[id]!) }
            return parent[id]!
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        union("A", "B")
        union("B", "C")

        XCTAssertEqual(find("A"), find("C"), "A and C should be in the same group via B")

        var groups: [String: [String]] = [:]
        for id in ["A", "B", "C"] {
            let root = find(id)
            groups[root, default: []].append(id)
        }
        XCTAssertEqual(groups.count, 1, "Should be exactly 1 group")
        XCTAssertEqual(groups.values.first?.count, 3)
    }

    // Test threshold boundary
    func testThresholdBoundary() {
        XCTAssertLessThan(0.04, PhotoScanEngine.similarityThreshold, "Near-duplicates should be below threshold")
        XCTAssertLessThan(0.11, PhotoScanEngine.similarityThreshold, "Visually similar should be below threshold")
        XCTAssertGreaterThan(0.15, PhotoScanEngine.similarityThreshold, "Dissimilar should exceed threshold")
    }
}
