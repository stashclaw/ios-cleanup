import XCTest
@testable import iOSCleanup

final class FileScanEngineTests: XCTestCase {

    func testFormattedSize50MB() {
        let file = LargeFile(
            id: UUID(),
            source: .filesystem(url: URL(filePath: "/tmp/x")),
            displayName: "x",
            byteSize: 52_428_800,
            creationDate: nil
        )
        // ByteCountFormatter may say "50 MB" or "52.4 MB" depending on style
        XCTAssertFalse(file.formattedSize.isEmpty)
        XCTAssertTrue(file.formattedSize.contains("MB") || file.formattedSize.contains("GB"))
    }

    func testFormattedSizeContainsUnit() {
        let file = LargeFile(
            id: UUID(),
            source: .filesystem(url: URL(filePath: "/tmp/y")),
            displayName: "y",
            byteSize: 1_073_741_824, // 1 GB
            creationDate: nil
        )
        XCTAssertTrue(file.formattedSize.contains("GB"))
    }

    func testFilesystemEnumerationWithTempFile() async throws {
        // Write a file just over 50 MB to temp directory
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSCleanupTest_\(UUID().uuidString).bin")

        let size = 51 * 1024 * 1024  // 51 MB
        let data = Data(repeating: 0xAB, count: size)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let engine = FileScanEngine()
        let results = try await engine.scan()

        let found = results.first { file in
            if case .filesystem(let url) = file.source {
                return url.lastPathComponent == tempURL.lastPathComponent
            }
            return false
        }

        XCTAssertNotNil(found, "Large temp file should appear in scan results")
        XCTAssertGreaterThanOrEqual(found?.byteSize ?? 0, FileScanEngine.minimumFileSizeBytes)
    }
}
