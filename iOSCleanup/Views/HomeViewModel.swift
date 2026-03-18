import Foundation
import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {

    enum ScanState {
        case idle, scanning, done, failed(String)
    }

    @Published var photoScanState: ScanState = .idle
    @Published var contactScanState: ScanState = .idle
    @Published var fileScanState: ScanState = .idle

    @Published var photoGroups: [PhotoGroup] = []
    @Published var contactMatches: [ContactMatch] = []
    @Published var largeFiles: [LargeFile] = []

    var reclaimableBytes: Int64 {
        largeFiles.reduce(0) { $0 + $1.byteSize }
    }

    var hasAnyResult: Bool {
        !photoGroups.isEmpty || !contactMatches.isEmpty || !largeFiles.isEmpty
    }

    // MARK: - Scans

    func scanPhotos() async {
        photoScanState = .scanning
        let engine = PhotoScanEngine()
        for await result in engine.scan() {
            switch result {
            case .success(let groups):
                photoGroups = groups
                photoScanState = .done
            case .failure(let error):
                photoScanState = .failed(error.localizedDescription)
            }
        }
        if case .scanning = photoScanState { photoScanState = .done }
    }

    func scanContacts() async {
        contactScanState = .scanning
        let engine = ContactScanEngine()
        do {
            contactMatches = try await engine.scan()
            contactScanState = .done
        } catch {
            contactScanState = .failed(error.localizedDescription)
        }
    }

    func scanFiles() async {
        fileScanState = .scanning
        let engine = FileScanEngine()
        do {
            largeFiles = try await engine.scan()
            fileScanState = .done
        } catch {
            fileScanState = .failed(error.localizedDescription)
        }
    }
}
