import Foundation
import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {

    enum ScanState {
        case idle, scanning, done, failed(String)
    }

    @Published var photoScanState: ScanState = .idle
    @Published var photoGroups: [PhotoGroup] = []

    var hasAnyResult: Bool {
        !photoGroups.isEmpty
    }

    var isAnyScanning: Bool {
        if case .scanning = photoScanState { return true }
        return false
    }

    var isAllDone: Bool {
        if case .done = photoScanState { return true }
        return false
    }

    var nearDuplicateCount: Int {
        photoGroups.filter { $0.reason == .nearDuplicate }.count
    }

    var similarCount: Int {
        photoGroups.filter { $0.reason == .visuallySimilar }.count
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
}
