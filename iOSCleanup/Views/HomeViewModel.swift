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

    // MARK: - Storage usage

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

    private var storageUsedBytes: Int64 {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (attrs?[.systemSize] as? Int64) ?? 0
        let free  = (attrs?[.systemFreeSize] as? Int64) ?? 0
        return total - free
    }

    private var storageTotalBytes: Int64 {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attrs?[.systemSize] as? Int64) ?? 0
    }

    // MARK: - Scans

    func scanPhotos() async {
        photoScanState = .scanning

        let lock = NSLock()
        var collected: [PhotoGroup] = []

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let engine = PhotoScanEngine()
                for await result in engine.scan() {
                    if case .success(let groups) = result {
                        let filtered = groups.filter { $0.reason == .nearDuplicate || $0.reason == .burstShot }
                        lock.withLock { collected.append(contentsOf: filtered) }
                    }
                }
            }

            group.addTask {
                let engine = DuplicateHashEngine()
                do {
                    for try await event in engine.scan() {
                        if case .duplicatesFound(let groups) = event {
                            lock.withLock { collected.append(contentsOf: groups) }
                        }
                    }
                } catch {}
            }

            group.addTask {
                let engine = SimilarityEngine()
                do {
                    for try await event in engine.scan() {
                        if case .groupsFound(let groups) = event {
                            lock.withLock { collected.append(contentsOf: groups) }
                        }
                    }
                } catch {}
            }

            group.addTask {
                let engine = BlurScanEngine()
                do {
                    for try await event in engine.scan() {
                        if case .blurryFound(let groups) = event {
                            lock.withLock { collected.append(contentsOf: groups) }
                        }
                    }
                } catch {}
            }
        }

        var seen = Set<Set<String>>()
        let unique = collected.filter { group in
            let key = Set(group.assets.map { $0.localIdentifier })
            return seen.insert(key).inserted
        }

        photoGroups = unique
        photoScanState = .done
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
