import Foundation
import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {

    enum ScanState {
        case idle, scanning, done, failed(String)
    }

    // Storage is cached at init; call refreshStorageInfo() if you need fresh values.
    private(set) var storageUsedBytes: Int64 = 0
    private(set) var storageTotalBytes: Int64 = 0

    init() {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (attrs?[.systemSize] as? Int64) ?? 0
        let free  = (attrs?[.systemFreeSize] as? Int64) ?? 0
        storageTotalBytes = total
        storageUsedBytes  = total - free
    }

    func refreshStorageInfo() {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (attrs?[.systemSize] as? Int64) ?? 0
        let free  = (attrs?[.systemFreeSize] as? Int64) ?? 0
        storageTotalBytes = total
        storageUsedBytes  = total - free
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

    var reclaimableFormatted: String {
        ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
    }

    var hasAnyResult: Bool {
        !photoGroups.isEmpty || !contactMatches.isEmpty || !largeFiles.isEmpty
    }

    var isAnyScanning: Bool {
        [photoScanState, contactScanState, fileScanState].contains { if case .scanning = $0 { return true }; return false }
    }

    var isAllDone: Bool {
        let states = [photoScanState, contactScanState, fileScanState]
        return states.allSatisfy { if case .done = $0 { return true }; return false }
    }

    // MARK: - Storage usage (values cached at init, call refreshStorageInfo() if needed)

    var storageUsedFraction: Double {
        let total = storageTotalBytes
        guard total > 0 else { return 0 }
        return Double(storageUsedBytes) / Double(total)
    }

    var storageUsedFormatted: String {
        ByteCountFormatter.string(fromByteCount: storageUsedBytes, countStyle: .file) + " used"
    }

    var storageTotalFormatted: String {
        ByteCountFormatter.string(fromByteCount: storageTotalBytes, countStyle: .file) + " total"
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
