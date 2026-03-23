import Foundation
import Photos
import SwiftUI

@MainActor
final class SwipeModeViewModel: ObservableObject {

    // MARK: - Queue entry

    enum QueueEntry: Identifiable {
        case asset(PHAsset, groupID: UUID)
        case monthHeader(String)

        var id: String {
            switch self {
            case .asset(let a, _): return a.localIdentifier
            case .monthHeader(let s): return "header-\(s)"
            }
        }
    }

    // MARK: - State

    @Published var queue: [QueueEntry] = []
    @Published var currentIndex: Int = 0
    @Published var isComplete = false
    @Published var deleteError: String?

    private var keptAssets: [PHAsset] = []
    private var toDeleteAssets: [PHAsset] = []
    private(set) var deletedCount = 0
    private(set) var deletedBytes: Int64 = 0

    var keptCount: Int { keptAssets.count }
    var duckedCount: Int { toDeleteAssets.count + deletedCount }

    init(groups: [PhotoGroup]) {
        buildQueue(from: groups)
    }

    var current: QueueEntry? {
        guard currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var progress: Double {
        guard !queue.isEmpty else { return 1 }
        return Double(currentIndex) / Double(queue.count)
    }

    // MARK: - Actions

    /// Swipe right = keep
    func keep() {
        if case .asset(let asset, _) = current {
            keptAssets.append(asset)
        }
        advance()
    }

    /// Swipe left = delete (individual deletes are free)
    func delete() {
        if case .asset(let asset, _) = current {
            toDeleteAssets.append(asset)
        }
        advance()
    }

    private func advance() {
        currentIndex += 1
        // Skip headers automatically
        while currentIndex < queue.count, case .monthHeader = queue[currentIndex] {
            currentIndex += 1
        }
        if currentIndex >= queue.count {
            isComplete = true
            // commitDeletes() is called explicitly by the completion screen (paid gate)
        }
    }

    // MARK: - Bulk confirm (paid) — called from completion screen after purchase check

    func commitDeletes() async {
        guard !toDeleteAssets.isEmpty else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(self.toDeleteAssets as NSFastEnumeration)
            }
            deletedCount = toDeleteAssets.count
            toDeleteAssets.removeAll()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    // MARK: - Queue building

    private func buildQueue(from groups: [PhotoGroup]) {
        // Gather all non-best assets sorted by creation date
        let assets: [(PHAsset, UUID)] = groups.flatMap { group in
            group.assets.dropFirst().map { ($0, group.id) }
        }
        .sorted { ($0.0.creationDate ?? .distantPast) < ($1.0.creationDate ?? .distantPast) }

        // Insert month section headers
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"

        var lastMonth = ""
        var entries: [QueueEntry] = []
        for (asset, groupID) in assets {
            let month = formatter.string(from: asset.creationDate ?? Date())
            if month != lastMonth {
                entries.append(.monthHeader(month))
                lastMonth = month
            }
            entries.append(.asset(asset, groupID: groupID))
        }

        // Start at first asset (skip any leading headers)
        queue = entries
        currentIndex = 0
        while currentIndex < queue.count, case .monthHeader = queue[currentIndex] {
            currentIndex += 1
        }
    }
}
