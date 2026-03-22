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

}
