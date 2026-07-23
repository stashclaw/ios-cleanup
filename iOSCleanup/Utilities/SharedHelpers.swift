import Foundation
import Photos
import SwiftUI
import UIKit

private final class PhotoImageRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<UIImage?, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setRequestID(_ requestID: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()

        if shouldCancel {
            manager.cancelImageRequest(requestID)
        }
    }

    func resolve(_ image: UIImage?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }

    func cancel(using manager: PHImageManager) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
        }
        continuation?.resume(returning: nil)
    }
}

// MARK: - String Deduplication

extension Array where Element == String {
    /// Returns the array with duplicates removed, preserving the order of first occurrence.
    func uniquePreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Numeric Clamping

func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
    Swift.min(Swift.max(value, lower), upper)
}

// MARK: - PHAsset Convenience

extension PHAsset {
    /// Whether the asset has been edited (modification date > 1s from creation date).
    var isEdited: Bool {
        guard let creationDate, let modificationDate else { return false }
        return abs(modificationDate.timeIntervalSince(creationDate)) > 1
    }
}

extension Sequence where Element == PHAsset {
    /// Total estimated file size of all assets in the sequence.
    var totalFileSize: Int64 {
        reduce(into: Int64(0)) { $0 += $1.estimatedFileSize }
    }

    /// Returns assets sorted by creation date with `.distantPast` fallback for nil dates.
    func sortedByCreationDate(ascending: Bool = true) -> [PHAsset] {
        sorted { a, b in
            let aDate = a.creationDate ?? .distantPast
            let bDate = b.creationDate ?? .distantPast
            return ascending ? aDate < bDate : aDate > bDate
        }
    }
}

// MARK: - PhotoGroup Convenience

extension Sequence where Element == PhotoGroup {
    /// Total reclaimable bytes across all groups.
    var totalReclaimableBytes: Int64 {
        reduce(into: Int64(0)) { $0 += $1.reclaimableBytes }
    }
}

// MARK: - Byte Formatting

extension Int64 {
    /// Human-readable file size string (e.g. "3.5 MB").
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

// MARK: - Image Loading

extension PHAsset {
    /// Loads one usable image and guarantees the continuation is resumed once.
    /// Thumbnail callers should accept degraded results so iCloud or low-memory
    /// delivery cannot leave an awaiting task suspended indefinitely.
    func loadImage(
        targetSize: CGSize,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        allowNetwork: Bool = false,
        contentMode: PHImageContentMode = .aspectFill,
        acceptsDegradedResult: Bool = true,
        timeout: TimeInterval = 15
    ) async -> UIImage? {
        let manager = PHImageManager.default()
        let state = PhotoImageRequestState()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)

                let options = PHImageRequestOptions()
                options.deliveryMode = deliveryMode
                options.isSynchronous = false
                options.isNetworkAccessAllowed = allowNetwork
                options.resizeMode = deliveryMode == .opportunistic ? .exact : .fast

                let requestID = manager.requestImage(
                    for: self,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        state.resolve(nil)
                        return
                    }

                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                    let requestError = info?[PHImageErrorKey] as? Error
                    if let image, acceptsDegradedResult || !isDegraded {
                        state.resolve(image)
                    } else if requestError != nil || (image == nil && !isDegraded) {
                        state.resolve(nil)
                    }
                }
                state.setRequestID(requestID, manager: manager)

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    state.cancel(using: manager)
                }
            }
        } onCancel: {
            state.cancel(using: manager)
        }
    }
}

// MARK: - Animation Constants

extension Animation {
    /// Standard spring animation used throughout the app.
    static let duckSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)
}

// MARK: - Scan Constants

enum ScanWindows {
    /// Time window for clustering temporally-close photos (30 minutes).
    static let clusterWindowSeconds: TimeInterval = 30 * 60
    /// Number of days to consider a photo "recent".
    static let recentPhotosDays = -30
}

@MainActor
enum DuckHaptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func rigid() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
}
