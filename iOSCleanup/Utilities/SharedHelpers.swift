import Foundation
import Photos
import SwiftUI
import UIKit

enum PhotoAssetIdentity {
    /// PhotoKit can return the same logical asset through multiple result
    /// collections. Keep the first live object for each identifier so repeated
    /// scan updates never produce duplicate tiles, byte totals, or deletions.
    static func unique(_ assets: [PHAsset]) -> [PHAsset] {
        var seen = Set<String>()
        return assets.filter {
            seen.insert($0.localIdentifier).inserted
        }
    }

    static func uniqueIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }
}

final class PhotoImageRequestState: @unchecked Sendable {
    typealias RequestCanceller = @Sendable (PHImageRequestID) -> Void

    private final class RequestExecutor: @unchecked Sendable {
        private let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.photoduck.image-request-launch"
            queue.qualityOfService = .utility
            queue.maxConcurrentOperationCount = 8
            return queue
        }()
        private let lock = NSLock()
        private var scheduledCount = 0
        private let maximumScheduledCount = 16

        func submit(
            _ operation: @escaping @Sendable () -> Void
        ) -> Bool {
            lock.lock()
            guard scheduledCount < maximumScheduledCount else {
                lock.unlock()
                return false
            }
            scheduledCount += 1
            lock.unlock()

            queue.addOperation { [self] in
                defer {
                    lock.lock()
                    scheduledCount -= 1
                    lock.unlock()
                }
                operation()
            }
            return true
        }
    }

    private final class CancellationExecutor: @unchecked Sendable {
        private let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.photoduck.image-request-cancellation"
            queue.qualityOfService = .utility
            // A single PhotoKit cancellation can block internally. Two workers
            // let the next cancellation begin without creating one thread per
            // timeout across a very large library.
            queue.maxConcurrentOperationCount = 2
            return queue
        }()
        private let lock = NSLock()
        private var scheduledCount = 0
        private let maximumScheduledCount = 8

        func submit(
            requestID: PHImageRequestID,
            cancelRequest: @escaping RequestCanceller
        ) {
            lock.lock()
            guard scheduledCount < maximumScheduledCount else {
                lock.unlock()
                return
            }
            scheduledCount += 1
            lock.unlock()

            queue.addOperation { [self] in
                defer {
                    lock.lock()
                    scheduledCount -= 1
                    lock.unlock()
                }
                cancelRequest(requestID)
            }
        }
    }

    /// PhotoKit cancellation is best effort. Keeping it off the timeout path is
    /// critical: `cancelImageRequest` can block behind PhotoKit work for an old
    /// or iCloud-only asset, but an awaiting scan batch must still make progress.
    private static let cancellationExecutor = CancellationExecutor()
    private static let requestExecutor = RequestExecutor()

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

    func setRequestID(
        _ requestID: PHImageRequestID,
        cancelRequest: @escaping RequestCanceller
    ) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()

        if shouldCancel {
            Self.cancelAsynchronously(
                requestID,
                cancelRequest: cancelRequest
            )
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

    func isPending() -> Bool {
        lock.lock()
        let pending = !isFinished
        lock.unlock()
        return pending
    }

    func cancel(cancelRequest: @escaping RequestCanceller) {
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

        // Resume first. A synchronous PhotoKit cancellation must never be able
        // to strand the continuation and hold an entire eight-photo batch at 0.
        continuation?.resume(returning: nil)
        if requestID != PHInvalidImageRequestID {
            Self.cancelAsynchronously(
                requestID,
                cancelRequest: cancelRequest
            )
        }
    }

    private static func cancelAsynchronously(
        _ requestID: PHImageRequestID,
        cancelRequest: @escaping RequestCanceller
    ) {
        cancellationExecutor.submit(
            requestID: requestID,
            cancelRequest: cancelRequest
        )
    }

    static func requestAsynchronously(
        _ operation: @escaping @Sendable () -> Void
    ) -> Bool {
        requestExecutor.submit(operation)
    }
}

enum PhotoImageQualityIntent: Int, Sendable, Hashable {
    case thumbnail
    case review
    case fullscreen
    case analysisFast
    case analysis

    fileprivate var taskPriority: TaskPriority {
        switch self {
        case .review, .fullscreen:
            return .userInitiated
        case .thumbnail, .analysisFast, .analysis:
            return .utility
        }
    }
}

struct PhotoImageRequestKey: Sendable, Hashable {
    let localIdentifier: String
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let contentMode: Int
    let qualityIntent: PhotoImageQualityIntent
    let allowsNetworkAccess: Bool

    init(
        localIdentifier: String,
        modificationDate: Date?,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        qualityIntent: PhotoImageQualityIntent,
        allowsNetworkAccess: Bool
    ) {
        self.localIdentifier = localIdentifier
        self.modificationDate = modificationDate
        pixelWidth = Self.normalizedDimension(targetSize.width)
        pixelHeight = Self.normalizedDimension(targetSize.height)
        self.contentMode = contentMode == .aspectFit ? 0 : 1
        self.qualityIntent = qualityIntent
        self.allowsNetworkAccess = allowsNetworkAccess
    }

    private static func normalizedDimension(_ dimension: CGFloat) -> Int {
        guard dimension.isFinite, dimension >= 0, dimension < 100_000 else {
            // PHImageManagerMaximumSize intentionally means "original", and
            // should coalesce independently from every finite thumbnail size.
            return -1
        }
        return Int(dimension.rounded(.up))
    }
}

private struct SendablePhotoImage: @unchecked Sendable {
    let value: UIImage
}

/// The single image request and decoded-image cache used by PhotoDuck.
///
/// Identical requests share one PhotoKit operation. Each awaiting view owns a
/// consumer token, so disappearing views only cancel PhotoKit after the final
/// consumer leaves. The cache is bounded by decoded pixel bytes rather than
/// compressed file size.
actor PhotoImageRepository {
    static let shared = PhotoImageRepository()

    typealias ImageOperation = @Sendable () async -> UIImage?

    private struct CacheEntry {
        let image: SendablePhotoImage
        let decodedByteCost: Int
        var accessOrdinal: UInt64
    }

    private struct InFlightRequest {
        let task: Task<SendablePhotoImage?, Never>
        var consumerIDs: Set<UUID>
    }

    private let maximumDecodedByteCost: Int
    private var cachedImages: [PhotoImageRequestKey: CacheEntry] = [:]
    private var inFlightRequests: [PhotoImageRequestKey: InFlightRequest] = [:]
    private var totalDecodedByteCost = 0
    private var accessOrdinal: UInt64 = 0

    init(maximumDecodedByteCost: Int = 96 * 1_024 * 1_024) {
        self.maximumDecodedByteCost = max(maximumDecodedByteCost, 1)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.removeAllCachedImages() }
        }
    }

    func image(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        qualityIntent: PhotoImageQualityIntent,
        allowNetworkAccess: Bool
    ) async -> UIImage? {
        let key = PhotoImageRequestKey(
            localIdentifier: asset.localIdentifier,
            modificationDate: asset.modificationDate,
            targetSize: targetSize,
            contentMode: contentMode,
            qualityIntent: qualityIntent,
            allowsNetworkAccess: allowNetworkAccess
        )
        let deliveryMode: PHImageRequestOptionsDeliveryMode
        let acceptsDegradedResult: Bool
        let timeout: TimeInterval
        switch qualityIntent {
        case .thumbnail:
            deliveryMode = .opportunistic
            acceptsDegradedResult = true
            timeout = 8
        case .review:
            deliveryMode = .highQualityFormat
            acceptsDegradedResult = false
            timeout = 20
        case .fullscreen:
            deliveryMode = .highQualityFormat
            acceptsDegradedResult = false
            timeout = 30
        case .analysisFast:
            deliveryMode = .fastFormat
            acceptsDegradedResult = false
            timeout = 4
        case .analysis:
            deliveryMode = .highQualityFormat
            acceptsDegradedResult = false
            timeout = allowNetworkAccess ? 15 : 6
        }

        return await image(for: key) {
            await asset.loadImage(
                targetSize: targetSize,
                deliveryMode: deliveryMode,
                allowNetwork: allowNetworkAccess,
                contentMode: contentMode,
                acceptsDegradedResult: acceptsDegradedResult,
                timeout: timeout
            )
        }
    }

    /// Internal operation-based entry point keeps the coalescing policy
    /// deterministic and testable without constructing PhotoKit assets.
    func image(
        for key: PhotoImageRequestKey,
        operation: @escaping ImageOperation
    ) async -> UIImage? {
        if var entry = cachedImages[key] {
            accessOrdinal &+= 1
            entry.accessOrdinal = accessOrdinal
            cachedImages[key] = entry
            return entry.image.value
        }

        let consumerID = UUID()
        let sharedTask: Task<SendablePhotoImage?, Never>
        if var request = inFlightRequests[key] {
            request.consumerIDs.insert(consumerID)
            sharedTask = request.task
            inFlightRequests[key] = request
        } else {
            sharedTask = Task(priority: key.qualityIntent.taskPriority) {
                await operation().map(SendablePhotoImage.init(value:))
            }
            inFlightRequests[key] = InFlightRequest(
                task: sharedTask,
                consumerIDs: [consumerID]
            )
        }

        return await withTaskCancellationHandler {
            let result = await sharedTask.value
            return finishConsumer(
                consumerID,
                for: key,
                result: result
            )?.value
        } onCancel: {
            Task {
                await self.cancelConsumer(consumerID, for: key)
            }
        }
    }

    func removeAllCachedImages() {
        cachedImages.removeAll(keepingCapacity: true)
        totalDecodedByteCost = 0
    }

    #if DEBUG
    func debugCachedImageCount() -> Int {
        cachedImages.count
    }

    func debugInFlightRequestCount() -> Int {
        inFlightRequests.count
    }
    #endif

    private func finishConsumer(
        _ consumerID: UUID,
        for key: PhotoImageRequestKey,
        result: SendablePhotoImage?
    ) -> SendablePhotoImage? {
        guard var request = inFlightRequests[key],
              request.consumerIDs.remove(consumerID) != nil else {
            return result
        }

        if let result, cachedImages[key] == nil {
            store(result, for: key)
        }
        if request.consumerIDs.isEmpty {
            inFlightRequests.removeValue(forKey: key)
        } else {
            inFlightRequests[key] = request
        }
        return result
    }

    private func cancelConsumer(
        _ consumerID: UUID,
        for key: PhotoImageRequestKey
    ) {
        guard var request = inFlightRequests[key],
              request.consumerIDs.remove(consumerID) != nil else {
            return
        }
        if request.consumerIDs.isEmpty {
            request.task.cancel()
            inFlightRequests.removeValue(forKey: key)
        } else {
            inFlightRequests[key] = request
        }
    }

    private func store(_ image: SendablePhotoImage, for key: PhotoImageRequestKey) {
        let byteCost = Self.decodedByteCost(of: image.value)
        guard byteCost <= maximumDecodedByteCost else { return }

        accessOrdinal &+= 1
        cachedImages[key] = CacheEntry(
            image: image,
            decodedByteCost: byteCost,
            accessOrdinal: accessOrdinal
        )
        totalDecodedByteCost += byteCost

        while totalDecodedByteCost > maximumDecodedByteCost,
              let leastRecentlyUsed = cachedImages.min(by: {
                  $0.value.accessOrdinal < $1.value.accessOrdinal
              }) {
            totalDecodedByteCost -= leastRecentlyUsed.value.decodedByteCost
            cachedImages.removeValue(forKey: leastRecentlyUsed.key)
        }
    }

    private static func decodedByteCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(cgImage.bytesPerRow * cgImage.height, 1)
        }
        let pixelWidth = max(Int((image.size.width * image.scale).rounded(.up)), 1)
        let pixelHeight = max(Int((image.size.height * image.scale).rounded(.up)), 1)
        return pixelWidth * pixelHeight * 4
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

    /// Stat-tile variant: ByteCountFormatter renders 0 as the spelled-out
    /// "Zero KB", which reads as a bug on a dashboard. Show "0 MB" instead.
    var formattedBytesStat: String {
        self == 0 ? "0 MB" : formattedBytes
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
        let cancelRequest: PhotoImageRequestState.RequestCanceller = {
            requestID in
            manager.cancelImageRequest(requestID)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    state.cancel(cancelRequest: cancelRequest)
                }

                let requestWasScheduled =
                    PhotoImageRequestState.requestAsynchronously {
                        guard state.isPending() else { return }
                        let options = PHImageRequestOptions()
                        options.deliveryMode = deliveryMode
                        options.isSynchronous = false
                        options.isNetworkAccessAllowed = allowNetwork
                        options.resizeMode =
                            deliveryMode == .opportunistic
                                ? .exact
                                : .fast
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

                            let isDegraded =
                                (info?[PHImageResultIsDegradedKey] as? Bool)
                                == true
                            let requestError =
                                info?[PHImageErrorKey] as? Error
                            if let image,
                               acceptsDegradedResult || !isDegraded {
                                state.resolve(image)
                            } else if requestError != nil
                                || (image == nil && !isDegraded) {
                                state.resolve(nil)
                            }
                        }
                        state.setRequestID(
                            requestID,
                            cancelRequest: cancelRequest
                        )
                    }
                if !requestWasScheduled {
                    state.resolve(nil)
                }
            }
        } onCancel: {
            state.cancel(cancelRequest: cancelRequest)
        }
    }
}

// MARK: - Privacy-safe diagnostics

enum PhotoDuckDiagnosticSnapshotRepair: String, Sendable {
    case notNeeded = "not_needed"
    case repaired
    case discarded
}

enum PhotoDuckDiagnosticControlAction: String, Sendable {
    case resumeRequested = "resume_requested"
    case pauseRequested = "pause_requested"
}

enum PhotoDuckDiagnosticTerminationOutcome: String, Sendable {
    case completed
    case cancelled
    case permissionRequired = "permission_required"
    case failed
}

enum PhotoDuckDiagnosticSupportingScanAction: String, Sendable {
    case started
    case finished
}

enum PhotoDuckDiagnosticFailureKind: String, Sendable {
    case permission
    case photoScan = "photo_scan"
    case videoScan = "video_scan"
}

struct PhotoDuckDiagnosticFailure: Sendable {
    fileprivate let kind: PhotoDuckDiagnosticFailureKind
    fileprivate let code: Int

    /// This is the only boundary that accepts an Error. It deliberately keeps
    /// the numeric code and a caller-selected category, never the domain,
    /// localized description, filename, path, or other NSError userInfo.
    init(
        kind: PhotoDuckDiagnosticFailureKind,
        error: any Error
    ) {
        self.kind = kind
        code = (error as NSError).code
    }
}

/// A deliberately narrow diagnostic event. Callers can only construct one of
/// the typed events below, which keeps asset identifiers, filenames, paths,
/// personal data, and arbitrary error messages out of the persistent support log.
struct PhotoDuckDiagnosticEvent: Sendable {
    fileprivate let timestamp: Date
    fileprivate let processUptime: TimeInterval
    fileprivate let category: String
    fileprivate let name: String
    fileprivate let fields: [String: String]

    private init(
        timestamp: Date,
        category: String,
        name: String,
        fields: [String: String]
    ) {
        self.timestamp = timestamp
        processUptime = ProcessInfo.processInfo.systemUptime
        self.category = category
        self.name = name
        self.fields = fields
    }

    static func appLaunched(
        appVersion: String,
        buildVersion: String,
        osVersion: String,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "lifecycle",
            name: "app_launched",
            fields: [
                "app_version": appVersion,
                "build_version": buildVersion,
                "os_version": osVersion
            ]
        )
    }

    static func sceneChanged(
        phase: String,
        scanState: String,
        processedCount: Int,
        targetCount: Int,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "lifecycle",
            name: "scene_changed",
            fields: [
                "phase": phase,
                "scan_state": scanState,
                "processed": String(processedCount),
                "target": String(targetCount)
            ]
        )
    }

    static func restoredState(
        scanState: String,
        processedCount: Int,
        targetCount: Int,
        hasCompletionDate: Bool,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "photo_scan",
            name: "state_restored",
            fields: [
                "scan_state": scanState,
                "processed": String(processedCount),
                "target": String(targetCount),
                "has_completion_date": String(hasCompletionDate)
            ]
        )
    }

    static func photoScanRequested(
        mode: String,
        previousState: String,
        forceFullRescan: Bool,
        retryUnanalyzed: Bool,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "photo_scan",
            name: "requested",
            fields: [
                "mode": mode,
                "previous_state": previousState,
                "force_full_rescan": String(forceFullRescan),
                "retry_unanalyzed": String(retryUnanalyzed)
            ]
        )
    }

    static func photoScanPlanned(
        libraryCount: Int,
        snapshotFound: Bool,
        snapshotComplete: Bool,
        snapshotConsistent: Bool,
        snapshotRepairOutcome: PhotoDuckDiagnosticSnapshotRepair,
        requiredCount: Int?,
        isResume: Bool,
        progressOffset: Int,
        targetCount: Int,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "photo_scan",
            name: "plan_selected",
            fields: [
                "library_count": String(libraryCount),
                "snapshot_found": String(snapshotFound),
                "snapshot_complete": String(snapshotComplete),
                "snapshot_consistent": String(snapshotConsistent),
                "snapshot_repair": snapshotRepairOutcome.rawValue,
                "required_count": requiredCount.map(String.init) ?? "full_plan",
                "is_resume": String(isResume),
                "progress_offset": String(progressOffset),
                "target": String(targetCount)
            ]
        )
    }

    static func photoScanNoWork(
        libraryCount: Int,
        processedCount: Int,
        targetCount: Int,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "photo_scan",
            name: "unchanged_cache_reused",
            fields: [
                "library_count": String(libraryCount),
                "processed": String(processedCount),
                "target": String(targetCount)
            ]
        )
    }

    static func photoScanProgress(
        processedCount: Int,
        targetCount: Int,
        analyzedCount: Int,
        unanalyzedCount: Int,
        groupCount: Int,
        progressPercent: Int,
        isCompleteUpdate: Bool,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "photo_scan",
            name: isCompleteUpdate ? "final_update" : "progress",
            fields: [
                "processed": String(processedCount),
                "target": String(targetCount),
                "analyzed": String(analyzedCount),
                "unanalyzed": String(unanalyzedCount),
                "groups": String(groupCount),
                "percent": String(progressPercent)
            ]
        )
    }

    static func photoScanControl(
        action: PhotoDuckDiagnosticControlAction,
        processedCount: Int,
        targetCount: Int,
        engineWasActive: Bool,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "photo_scan",
            name: action.rawValue,
            fields: [
                "processed": String(processedCount),
                "target": String(targetCount),
                "engine_active": String(engineWasActive)
            ]
        )
    }

    static func photoScanTerminated(
        outcome: PhotoDuckDiagnosticTerminationOutcome,
        processedCount: Int,
        targetCount: Int,
        analyzedCount: Int,
        unanalyzedCount: Int,
        groupCount: Int,
        failure: PhotoDuckDiagnosticFailure? = nil,
        at timestamp: Date = Date()
    ) -> Self {
        var fields = [
            "outcome": outcome.rawValue,
            "processed": String(processedCount),
            "target": String(targetCount),
            "analyzed": String(analyzedCount),
            "unanalyzed": String(unanalyzedCount),
            "groups": String(groupCount)
        ]
        if let failure {
            fields["error_kind"] = failure.kind.rawValue
            fields["error_code"] = String(failure.code)
        }
        return Self(
            timestamp: timestamp,
            category: "photo_scan",
            name: "terminated",
            fields: fields
        )
    }

    static func supportingScans(
        action: PhotoDuckDiagnosticSupportingScanAction,
        fileState: String,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "supporting_scans",
            name: action.rawValue,
            fields: [
                "file_state": fileState
            ]
        )
    }

    static func videoScanRequested(
        force: Bool,
        previousState: String,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "video_scan",
            name: "requested",
            fields: [
                "force": String(force),
                "previous_state": previousState
            ]
        )
    }

    static func videoScanProgress(
        totalCount: Int,
        processedCount: Int,
        cacheHitCount: Int,
        qualifyingCount: Int,
        progressPercent: Int,
        isComplete: Bool,
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            timestamp: timestamp,
            category: "video_scan",
            name: isComplete ? "completed" : "progress",
            fields: [
                "total": String(totalCount),
                "processed": String(processedCount),
                "cache_hits": String(cacheHitCount),
                "qualifying": String(qualifyingCount),
                "percent": String(progressPercent)
            ]
        )
    }

    static func videoScanTerminated(
        outcome: PhotoDuckDiagnosticTerminationOutcome,
        totalCount: Int,
        processedCount: Int,
        cacheHitCount: Int,
        failure: PhotoDuckDiagnosticFailure? = nil,
        at timestamp: Date = Date()
    ) -> Self {
        var fields = [
            "outcome": outcome.rawValue,
            "total": String(totalCount),
            "processed": String(processedCount),
            "cache_hits": String(cacheHitCount)
        ]
        if let failure {
            fields["error_kind"] = failure.kind.rawValue
            fields["error_code"] = String(failure.code)
        }
        return Self(
            timestamp: timestamp,
            category: "video_scan",
            name: "terminated",
            fields: fields
        )
    }
}

struct PhotoDuckDiagnosticCheckpointSummary: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generation: UInt64
    let savedAt: Date
    let libraryCount: Int
    let targetCount: Int
    let processedCount: Int
    let analyzedCount: Int
    let unanalyzedCount: Int
    let groupCount: Int
    let reviewableCount: Int
    let evaluatedIdentifierCount: Int
    let plannedIdentifierCount: Int
    let isComplete: Bool
    let isConsistent: Bool
}

struct PhotoDuckDiagnosticReportSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let appVersion: String
    let buildVersion: String
    let osVersion: String
    let deviceModel: String
    let photoAuthorization: String
    let scanState: String
    let cleanupMode: String
    let freshnessState: String
    let isPaused: Bool
    let isFinalizingPhotoScan: Bool
    let isFinishingSupportingScans: Bool
    let libraryCount: Int
    let targetCount: Int
    let processedCount: Int
    let analyzedCount: Int
    let unanalyzedCount: Int
    let groupCount: Int
    let reviewableCount: Int
    let reclaimablePhotoBytes: Int64
    let lastCompletedAt: Date?
    let fileScanState: String
    let videoTotalCount: Int
    let videoProcessedCount: Int
    let videoCacheHitCount: Int
    let qualifyingLargeVideoCount: Int
    let qualifyingLargeVideoBytes: Int64
    let cachePersistenceHealthy: Bool
    let checkpoint: PhotoDuckDiagnosticCheckpointSummary?
}

struct PhotoDuckDiagnosticStoredEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let processUptime: TimeInterval
    let sessionID: String
    let category: String
    let name: String
    let fields: [String: String]
}

struct PhotoDuckDiagnosticReportEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let privacyNotice =
        "Contains PhotoDuck states, counts, timings, and sanitized error codes. "
        + "Contains no photos, thumbnails, asset identifiers, filenames, paths, "
        + "media dates, or locations. Diagnostic history is "
        + "bounded, so older events may be omitted."

    let schemaVersion: Int
    let privacyNotice: String
    let snapshot: PhotoDuckDiagnosticReportSnapshot
    let events: [PhotoDuckDiagnosticStoredEvent]
    let eventsTrimmedForExport: Bool
}

enum PhotoDuckDiagnosticExportError: LocalizedError {
    case reportExceedsSizeLimit

    var errorDescription: String? {
        "The diagnostic report could not be safely reduced to the size limit."
    }
}

/// Bounded, persistent support telemetry that survives a relaunch. It is
/// separate from unified logging so a user can explicitly share prior-session
/// resume evidence. Recording is nonthrowing and never blocks scan correctness.
actor PhotoDuckDiagnosticLog {
    static let shared = PhotoDuckDiagnosticLog()

    private let fileURL: URL
    private let maximumEventCount: Int
    private let maximumFileBytes: Int
    private let maximumExportBytes: Int
    private let retentionInterval: TimeInterval
    private let sessionID: String
    private let exportDirectoryURL: URL
    private let nowProvider: @Sendable () -> Date
    private var events: [PhotoDuckDiagnosticStoredEvent] = []
    private var currentFileBytes = 0
    private var hasLoaded = false

    init(
        fileURL: URL? = nil,
        maximumEventCount: Int = 600,
        maximumFileBytes: Int = 512 * 1_024,
        maximumExportBytes: Int = 1_024 * 1_024,
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60,
        sessionID: String = String(UUID().uuidString.prefix(8)),
        exportDirectoryURL: URL? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = baseURL
                .appendingPathComponent("PhotoDuck", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
                .appendingPathComponent("events-v1.jsonl")
        }
        self.maximumEventCount = max(maximumEventCount, 1)
        self.maximumFileBytes = max(maximumFileBytes, 512)
        self.maximumExportBytes = max(maximumExportBytes, 2_048)
        self.retentionInterval = max(retentionInterval, 60)
        self.sessionID = sessionID
        self.exportDirectoryURL =
            exportDirectoryURL ?? FileManager.default.temporaryDirectory
        self.nowProvider = nowProvider
    }

    func record(_ event: PhotoDuckDiagnosticEvent) {
        loadIfNeeded()
        let now = nowProvider()
        let storedEvent = PhotoDuckDiagnosticStoredEvent(
            // A wall-clock correction or malformed test input must not pin an
            // event in the future beyond the retention window.
            timestamp: min(event.timestamp, now),
            processUptime: event.processUptime,
            sessionID: Self.sanitize(event: sessionID, maximumLength: 16),
            category: Self.sanitize(event: event.category, maximumLength: 48),
            name: Self.sanitize(event: event.name, maximumLength: 64),
            fields: Self.sanitizedFields(event.fields)
        )
        events.append(storedEvent)
        sortEvents()
        if pruneEvents(relativeTo: now) {
            rewriteFile()
        } else {
            persistNewestEvent(storedEvent)
        }
    }

    func exportReport(
        snapshot: PhotoDuckDiagnosticReportSnapshot,
        currentSessionUptimeCutoff: TimeInterval? = nil
    ) throws -> URL {
        loadIfNeeded()
        if pruneEvents(relativeTo: nowProvider()) {
            rewriteFile()
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let safeSnapshot = Self.sanitizedSnapshot(snapshot)
        let currentSessionID = Self.sanitize(
            event: sessionID,
            maximumLength: 16
        )
        // Process uptime is monotonic within this app launch, so it remains a
        // strict point-in-time watermark even if the wall clock changes.
        var exportEvents = events.filter {
            guard $0.sessionID == currentSessionID,
                  let currentSessionUptimeCutoff else {
                return true
            }
            return $0.processUptime <= currentSessionUptimeCutoff
        }
        var envelope = PhotoDuckDiagnosticReportEnvelope(
            schemaVersion: PhotoDuckDiagnosticReportEnvelope.schemaVersion,
            privacyNotice: PhotoDuckDiagnosticReportEnvelope.privacyNotice,
            snapshot: safeSnapshot,
            events: exportEvents,
            eventsTrimmedForExport: false
        )
        var data = try encoder.encode(envelope)
        while data.count > maximumExportBytes, !exportEvents.isEmpty {
            exportEvents.removeFirst(max(exportEvents.count / 4, 1))
            envelope = PhotoDuckDiagnosticReportEnvelope(
                schemaVersion: PhotoDuckDiagnosticReportEnvelope.schemaVersion,
                privacyNotice: PhotoDuckDiagnosticReportEnvelope.privacyNotice,
                snapshot: safeSnapshot,
                events: exportEvents,
                eventsTrimmedForExport: true
            )
            data = try encoder.encode(envelope)
        }
        guard data.count <= maximumExportBytes else {
            throw PhotoDuckDiagnosticExportError.reportExceedsSizeLimit
        }
        let timestamp = Int(snapshot.generatedAt.timeIntervalSince1970 * 1_000)
        let nonce = UUID().uuidString
        let filename =
            "PhotoDuck-Diagnostics-\(timestamp)-\(nonce).json"
        try FileManager.default.createDirectory(
            at: exportDirectoryURL,
            withIntermediateDirectories: true
        )
        let exportURL = exportDirectoryURL
            .appendingPathComponent(filename)
        try data.write(to: exportURL, options: [.atomic])
        applyPrivacyAttributes(to: exportURL)
        return exportURL
    }

    /// Removes only stale PhotoDuck report exports. The persistent event ring
    /// is stored elsewhere and is never touched by this maintenance pass.
    func performStartupMaintenance(
        maximumExportAge: TimeInterval = 24 * 60 * 60
    ) {
        let cutoff = nowProvider().addingTimeInterval(
            -max(maximumExportAge, 60)
        )
        let keys: [URLResourceKey] = [
            .contentModificationDateKey,
            .creationDateKey,
            .isRegularFileKey
        ]
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: exportDirectoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix("PhotoDuck-Diagnostics-"),
                  candidate.pathExtension.lowercased() == "json",
                  let values = try? candidate.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }
            let fileDate =
                values.contentModificationDate
                ?? values.creationDate
                ?? .distantFuture
            if fileDate < cutoff {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
    }

    func storedEvents() -> [PhotoDuckDiagnosticStoredEvent] {
        loadIfNeeded()
        return events
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        prepareDirectory()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fileURL.path
            )
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount <= maximumFileBytes * 4 else {
                events = []
                rewriteFile()
                return
            }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let lines = data.split(separator: 0x0A)
            let missingTrailingNewline =
                !data.isEmpty && data.last != 0x0A
            var decodedEvents: [PhotoDuckDiagnosticStoredEvent] = []
            decodedEvents.reserveCapacity(lines.count)
            var foundMalformedLine = false
            for line in lines {
                if let event = try? decoder.decode(
                    PhotoDuckDiagnosticStoredEvent.self,
                    from: Data(line)
                ) {
                    decodedEvents.append(event)
                } else {
                    foundMalformedLine = true
                }
            }
            events = decodedEvents
            sortEvents()
            let didPruneEvents = pruneEvents(relativeTo: nowProvider())
            currentFileBytes = data.count
            if foundMalformedLine
                || missingTrailingNewline
                || didPruneEvents
                || events.count == maximumEventCount
                || currentFileBytes > maximumFileBytes {
                rewriteFile()
            }
        } catch {
            events = []
            currentFileBytes = 0
        }
    }

    @discardableResult
    private func pruneEvents(relativeTo date: Date) -> Bool {
        let originalCount = events.count
        let cutoff = date.addingTimeInterval(-retentionInterval)
        let futureTolerance: TimeInterval = 5 * 60
        let futureCutoff = date.addingTimeInterval(futureTolerance)
        events.removeAll {
            $0.timestamp < cutoff || $0.timestamp > futureCutoff
        }
        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
        return events.count != originalCount
    }

    private func sortEvents() {
        events.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            if lhs.processUptime != rhs.processUptime {
                return lhs.processUptime < rhs.processUptime
            }
            return lhs.sessionID < rhs.sessionID
        }
    }

    private func persistNewestEvent(
        _ event: PhotoDuckDiagnosticStoredEvent
    ) {
        guard let line = encodedLine(event) else { return }
        if events.count >= maximumEventCount
            || currentFileBytes + line.count > maximumFileBytes {
            rewriteFile()
            return
        }
        prepareDirectory()
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: [.atomic])
            }
            currentFileBytes += line.count
            applyPrivacyAttributes(to: fileURL)
        } catch {
            // Diagnostics must never change or fail scan behavior.
        }
    }

    private func rewriteFile() {
        prepareDirectory()
        var encoded = encodeCurrentEvents()
        while encoded.count > maximumFileBytes, !events.isEmpty {
            events.removeFirst(max(events.count / 4, 1))
            encoded = encodeCurrentEvents()
        }
        do {
            try encoded.write(to: fileURL, options: [.atomic])
            currentFileBytes = encoded.count
            applyPrivacyAttributes(to: fileURL)
        } catch {
            let existingAttributes =
                try? FileManager.default.attributesOfItem(
                    atPath: fileURL.path
                )
            currentFileBytes =
                (existingAttributes?[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    private func encodeCurrentEvents() -> Data {
        events.reduce(into: Data()) { data, event in
            if let line = encodedLine(event) {
                data.append(line)
            }
        }
    }

    private func encodedLine(
        _ event: PhotoDuckDiagnosticStoredEvent
    ) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(event) else { return nil }
        data.append(0x0A)
        return data
    }

    private func prepareDirectory() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        applyPrivacyAttributes(to: directory)
    }

    private func applyPrivacyAttributes(to url: URL) {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
        try? FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: url.path
        )
    }

    private static func sanitizedFields(
        _ fields: [String: String]
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: fields.keys.sorted().prefix(24).map { key in
                (
                    sanitize(event: key, maximumLength: 48),
                    sanitizedFieldValue(
                        fields[key] ?? "",
                        forKey: key
                    )
                )
            }
        )
    }

    private static func sanitizedFieldValue(
        _ value: String,
        forKey key: String
    ) -> String {
        let allowedValues: Set<String>?
        switch key {
        case "phase":
            allowedValues = ["active", "inactive", "background", "unknown"]
        case "scan_state", "previous_state", "file_state":
            allowedValues = [
                "idle",
                "scanning",
                "paused",
                "completed",
                "failed",
                "permissionRequired",
                "unknown"
            ]
        case "mode":
            allowedValues = ["speedClean", "deepClean", "unknown"]
        case "snapshot_repair":
            allowedValues = ["not_needed", "repaired", "discarded"]
        case "outcome":
            allowedValues = [
                "completed",
                "cancelled",
                "permission_required",
                "failed"
            ]
        case "error_kind":
            allowedValues = [
                "permission",
                "photo_scan",
                "video_scan"
            ]
        default:
            allowedValues = nil
        }
        if let allowedValues {
            return allowedValues.contains(value) ? value : "unknown"
        }
        return sanitize(event: value, maximumLength: 160)
    }

    private static func sanitizedSnapshot(
        _ snapshot: PhotoDuckDiagnosticReportSnapshot
    ) -> PhotoDuckDiagnosticReportSnapshot {
        PhotoDuckDiagnosticReportSnapshot(
            generatedAt: snapshot.generatedAt,
            appVersion: sanitize(
                event: snapshot.appVersion,
                maximumLength: 48
            ),
            buildVersion: sanitize(
                event: snapshot.buildVersion,
                maximumLength: 48
            ),
            osVersion: sanitize(
                event: snapshot.osVersion,
                maximumLength: 96
            ),
            deviceModel: sanitize(
                event: snapshot.deviceModel,
                maximumLength: 64
            ),
            photoAuthorization: allowlisted(
                snapshot.photoAuthorization,
                values: [
                    "not_determined",
                    "restricted",
                    "denied",
                    "authorized",
                    "limited",
                    "unknown"
                ]
            ),
            scanState: allowlisted(
                snapshot.scanState,
                values: diagnosticScanStates
            ),
            cleanupMode: allowlisted(
                snapshot.cleanupMode,
                values: ["speedClean", "deepClean", "unknown"]
            ),
            freshnessState: allowlisted(
                snapshot.freshnessState,
                values: ["live", "lastKnown", "stale", "unknown"]
            ),
            isPaused: snapshot.isPaused,
            isFinalizingPhotoScan: snapshot.isFinalizingPhotoScan,
            isFinishingSupportingScans:
                snapshot.isFinishingSupportingScans,
            libraryCount: snapshot.libraryCount,
            targetCount: snapshot.targetCount,
            processedCount: snapshot.processedCount,
            analyzedCount: snapshot.analyzedCount,
            unanalyzedCount: snapshot.unanalyzedCount,
            groupCount: snapshot.groupCount,
            reviewableCount: snapshot.reviewableCount,
            reclaimablePhotoBytes: snapshot.reclaimablePhotoBytes,
            lastCompletedAt: snapshot.lastCompletedAt,
            fileScanState: allowlisted(
                snapshot.fileScanState,
                values: diagnosticScanStates
            ),
            videoTotalCount: snapshot.videoTotalCount,
            videoProcessedCount: snapshot.videoProcessedCount,
            videoCacheHitCount: snapshot.videoCacheHitCount,
            qualifyingLargeVideoCount:
                snapshot.qualifyingLargeVideoCount,
            qualifyingLargeVideoBytes:
                snapshot.qualifyingLargeVideoBytes,
            cachePersistenceHealthy: snapshot.cachePersistenceHealthy,
            checkpoint: snapshot.checkpoint
        )
    }

    private static let diagnosticScanStates: Set<String> = [
        "idle",
        "scanning",
        "paused",
        "completed",
        "failed",
        "permissionRequired",
        "unknown"
    ]

    private static func allowlisted(
        _ value: String,
        values: Set<String>
    ) -> String {
        values.contains(value) ? value : "unknown"
    }

    private static func sanitize(
        event: String,
        maximumLength: Int
    ) -> String {
        let singleLine = event
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(singleLine.prefix(maximumLength))
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
