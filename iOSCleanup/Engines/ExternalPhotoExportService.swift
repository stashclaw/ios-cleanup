import Foundation
import Combine
import OSLog
@preconcurrency import Photos

enum ExportAlbumSelection {
    static func selectedAssets(
        in assets: [PHAsset],
        assetIDs: Set<String>
    ) -> [PHAsset] {
        PhotoAssetIdentity.unique(assets).filter {
            assetIDs.contains($0.localIdentifier)
        }
    }

    static func reconciledAssetIDs(
        _ selectedAssetIDs: Set<String>,
        availableAssetIDs: Set<String>
    ) -> Set<String> {
        selectedAssetIDs.intersection(availableAssetIDs)
    }
}

@MainActor
final class ExportAlbumStore: ObservableObject {
    private static let persistenceKey = "photoduck.export-album.v1"

    @Published private(set) var assetIDs: [String]
    @Published private(set) var assets: [PHAsset] = []

    private let defaults: UserDefaults
    private var assetIDSet: Set<String>

    init(defaults: UserDefaults = .standard) {
        let restoredAssetIDs =
            defaults.stringArray(forKey: Self.persistenceKey) ?? []
        self.defaults = defaults
        assetIDs = restoredAssetIDs
        assetIDSet = Set(restoredAssetIDs)
        Task { await refreshAssets() }
    }

    var count: Int {
        assetIDs.count
    }

    func contains(_ assetID: String) -> Bool {
        assetIDSet.contains(assetID)
    }

    func add(_ newAssets: [PHAsset]) {
        guard !newAssets.isEmpty else { return }
        var appendedAssets: [PHAsset] = []
        for asset in newAssets
        where assetIDSet.insert(asset.localIdentifier).inserted {
            assetIDs.append(asset.localIdentifier)
            appendedAssets.append(asset)
        }
        guard !appendedAssets.isEmpty else { return }
        let existingAssetIDs = Set(assets.map(\.localIdentifier))
        assets.append(
            contentsOf: appendedAssets.filter {
                !existingAssetIDs.contains($0.localIdentifier)
            }
        )
        persist()
    }

    func remove(assetIDs removedIDs: Set<String>) {
        guard !removedIDs.isEmpty else { return }
        assetIDSet.subtract(removedIDs)
        assetIDs.removeAll { removedIDs.contains($0) }
        assets.removeAll { removedIDs.contains($0.localIdentifier) }
        persist()
    }

    func clear() {
        assetIDSet.removeAll(keepingCapacity: true)
        assetIDs = []
        assets = []
        persist()
    }

    /// Puts back items removed optimistically for a deletion that was then
    /// undone or rejected. Assets that no longer exist are dropped by the
    /// refresh below.
    func restore(assetIDs restoredIDs: Set<String>) async {
        guard !restoredIDs.isEmpty else { return }
        let additions = restoredIDs.subtracting(assetIDSet)
        guard !additions.isEmpty else { return }
        for identifier in additions.sorted() {
            assetIDs.append(identifier)
            assetIDSet.insert(identifier)
        }
        persist()
        await refreshAssets()
    }

    func refreshAssets() async {
        let requestedAssetIDs = assetIDs
        guard !requestedAssetIDs.isEmpty else {
            assets = []
            return
        }
        let restoredAssets = await Task.detached(priority: .utility) {
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: requestedAssetIDs,
                options: nil
            )
            var restored: [PHAsset] = []
            restored.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                restored.append(asset)
            }
            return restored
        }.value

        // The user may add/remove items while the background fetch is running.
        // Merge by ID, then publish only the current album order.
        var assetsByID = Dictionary(
            uniqueKeysWithValues: assets.map {
                ($0.localIdentifier, $0)
            }
        )
        for asset in restoredAssets {
            assetsByID[asset.localIdentifier] = asset
        }
        assets = assetIDs.compactMap { assetsByID[$0] }
    }

    private func persist() {
        defaults.set(assetIDs, forKey: Self.persistenceKey)
    }
}

struct ExternalPhotoExportResult: Sendable {
    let directoryURL: URL
    let requestedAssetCount: Int
    let resumedAssetCount: Int
    let exportedAssetIDs: [String]
    /// Assets skipped because this destination already holds a verified copy
    /// of the same version. They are safe to delete from Photos.
    var alreadyExportedAssetIDs: [String] = []
    let failures: [ExternalPhotoExportItemFailure]
    let wasCancelled: Bool
    let fileCount: Int
    let processedFileCount: Int
    let totalPlannedFileCount: Int
    let totalBytes: Int64

    var assetCount: Int {
        exportedAssetIDs.count
    }

    var failedAssetCount: Int {
        failures.count
    }

    var hasPartialSuccess: Bool {
        !exportedAssetIDs.isEmpty
            && (wasCancelled || !failures.isEmpty)
    }
}

struct ExternalPhotoExportItemFailure: Sendable {
    let assetID: String
    let filename: String?
    let message: String
}

/// Live progress for an in-flight export. Large videos can take minutes per
/// file (iCloud download plus a slow Files provider), so the UI must be able
/// to show which file is moving and how far along it is.
struct ExternalPhotoExportProgress: Sendable {
    let completedFileCount: Int
    let totalFileCount: Int
    let currentFilename: String?
    let currentFileFraction: Double

    var overallFraction: Double {
        guard totalFileCount > 0 else { return 0 }
        let clamped = min(max(currentFileFraction, 0), 1)
        return (Double(completedFileCount) + clamped) / Double(totalFileCount)
    }
}

/// Keeps high-frequency export progress out of the parent review view. Holding
/// this reference in `@State` and observing it only from the compact progress
/// card prevents every progress tick from rebuilding thousands of rows.
@MainActor
final class ExternalPhotoExportProgressStore: ObservableObject {
    @Published private(set) var progress: ExternalPhotoExportProgress?

    func update(_ progress: ExternalPhotoExportProgress) {
        self.progress = progress
    }

    func reset() {
        progress = nil
    }
}

/// Prevents two view-local export surfaces from running at the same time.
/// Export mutates process-wide background and idle-timer state, so exclusivity
/// is a correctness requirement rather than only a UI convenience.
@MainActor
final class ExternalPhotoExportSessionGate {
    static let shared = ExternalPhotoExportSessionGate()

    private var activeToken: UUID?

    private init() {}

    func acquire() -> UUID? {
        guard activeToken == nil else { return nil }
        let token = UUID()
        activeToken = token
        return token
    }

    func release(_ token: UUID) {
        guard activeToken == token else { return }
        activeToken = nil
    }
}

enum ExternalPhotoExportError: Error, LocalizedError {
    case emptySelection
    case duplicateAssetIdentifiers
    case noExportableResources(String)
    case cannotCreateExportFolder
    case resourceWriteFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select at least one photo or video to export."
        case .duplicateAssetIdentifiers:
            return "The export selection contains the same item more than once."
        case .noExportableResources(let assetID):
            return "Item \(assetID) has no exportable resources. Nothing was deleted."
        case .cannotCreateExportFolder:
            return "PhotoDuck could not create a folder at that location. Choose another folder and try again."
        case .resourceWriteFailed(let filename):
            return "PhotoDuck could not finish exporting \(filename). Nothing was deleted."
        case .verificationFailed(let filename):
            return "PhotoDuck could not verify \(filename). Nothing was deleted."
        }
    }
}

struct ExternalPhotoExportManifest: Codable, Equatable, Sendable {
    struct AssetEntry: Codable, Equatable, Sendable {
        struct ResourceEntry: Codable, Equatable, Sendable {
            let originalFilename: String
            let exportedFilename: String
            let resourceType: Int
            let byteCount: Int64
        }

        let localIdentifier: String
        let creationDate: Date?
        let pixelWidth: Int
        let pixelHeight: Int
        /// Lets a later export recognise this exact version of the asset and
        /// skip re-copying it. Optional so manifests written before this
        /// existed still decode; a nil value simply forces a re-export.
        var modificationDate: Date?
        let resources: [ResourceEntry]
    }

    let exportedAt: Date
    let assets: [AssetEntry]
}

struct ExternalPhotoExportSessionRecord: Codable, Equatable, Sendable {
    struct AssetSignature: Codable, Equatable, Sendable {
        let localIdentifier: String
        let modificationDate: Date?
    }

    static let schemaVersion = 1

    let schemaVersion: Int
    let createdAt: Date
    let requestedAssets: [AssetSignature]
    let completedAssetIDs: [String]
    let isComplete: Bool
}

enum ExternalPhotoExportCapacity {
    static let minimumFreeSpaceReserveBytes: Int64 = 268_435_456

    static func hasCapacity(
        estimatedAssetBytes: Int64,
        availableBytes: Int64?
    ) -> Bool {
        guard estimatedAssetBytes > 0, let availableBytes else {
            return true
        }
        let required = estimatedAssetBytes.addingReportingOverflow(
            minimumFreeSpaceReserveBytes
        )
        return !required.overflow && availableBytes >= required.partialValue
    }
}

enum ExternalPhotoExportNaming {
    static func sanitizedFilename(_ filename: String) -> String {
        let fallback = "photo-resource"
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let components = filename.components(separatedBy: invalid)
        let cleaned = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".."
            ? fallback
            : cleaned
    }

    static func uniqueFilename(
        preferredName: String,
        assetIndex: Int,
        resourceIndex: Int,
        usedNames: inout Set<String>
    ) -> String {
        let sanitized = sanitizedFilename(preferredName)
        let url = URL(fileURLWithPath: sanitized)
        let stem = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension
        var candidate = sanitized
        var suffix = 1

        while usedNames.contains(candidate.lowercased()) {
            let disambiguator = "-\(assetIndex + 1)-\(resourceIndex + 1)-\(suffix)"
            candidate = stem + disambiguator
                + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
            suffix += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }
}

actor ExternalPhotoExportService {
    private struct RecoveryContext {
        let directoryURL: URL
        let session: ExternalPhotoExportSessionRecord
        let manifestEntries: [
            ExternalPhotoExportManifest.AssetEntry
        ]
    }

    private static let manifestFilename =
        "PhotoDuck Export Manifest.json"
    private static let sessionFilename =
        ".PhotoDuck Export Session.json"

    private let fileManager: FileManager
    private let resourceManager: PHAssetResourceManager

    init(
        fileManager: FileManager = .default,
        resourceManager: PHAssetResourceManager = .default()
    ) {
        self.fileManager = fileManager
        self.resourceManager = resourceManager
    }

    func export(
        assets: [PHAsset],
        to parentDirectoryURL: URL,
        now: Date = Date(),
        onProgress: @Sendable @escaping (ExternalPhotoExportProgress) -> Void = { _ in }
    ) async throws -> ExternalPhotoExportResult {
        guard !assets.isEmpty else {
            throw ExternalPhotoExportError.emptySelection
        }
        let identifiers = assets.map(\.localIdentifier)
        guard Set(identifiers).count == identifiers.count else {
            throw ExternalPhotoExportError.duplicateAssetIdentifiers
        }

        let accessedSecurityScope = parentDirectoryURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                parentDirectoryURL.stopAccessingSecurityScopedResource()
            }
        }

        let allSignatures = assetSignatures(for: assets)
        // Re-copying gigabytes that are already verified on this drive is the
        // single most expensive avoidable operation in the app.
        let alreadyExported = previouslyExportedAssetIDs(
            in: parentDirectoryURL,
            matching: allSignatures
        )
        let pendingAssets = assets.filter {
            !alreadyExported.contains($0.localIdentifier)
        }
        guard !pendingAssets.isEmpty else {
            // Everything requested is already safely on the drive. Report the
            // skips so the caller can still offer to delete the originals.
            return ExternalPhotoExportResult(
                directoryURL: parentDirectoryURL,
                requestedAssetCount: assets.count,
                resumedAssetCount: 0,
                exportedAssetIDs: [],
                alreadyExportedAssetIDs: Array(alreadyExported),
                failures: [],
                wasCancelled: false,
                fileCount: 0,
                processedFileCount: 0,
                totalPlannedFileCount: 0,
                totalBytes: 0
            )
        }

        let assets = pendingAssets
        let signatures = assetSignatures(for: assets)
        let recovery = resumableExport(
            in: parentDirectoryURL,
            matching: signatures
        )
        let exportDirectory: URL
        let initialManifestEntries:
            [ExternalPhotoExportManifest.AssetEntry]
        let sessionCreatedAt: Date
        if let recovery {
            exportDirectory = recovery.directoryURL
            initialManifestEntries = recovery.manifestEntries
            sessionCreatedAt = recovery.session.createdAt
        } else {
            exportDirectory = uniqueExportDirectory(
                in: parentDirectoryURL,
                now: now
            )
            do {
                try fileManager.createDirectory(
                    at: exportDirectory,
                    withIntermediateDirectories: false
                )
            } catch {
                throw ExternalPhotoExportError.cannotCreateExportFolder
            }
            initialManifestEntries = []
            sessionCreatedAt = now
            try? writeSession(
                signatures: signatures,
                completedAssetIDs: [],
                createdAt: sessionCreatedAt,
                isComplete: false,
                to: exportDirectory
            )
        }

        // Once an item has been copied and verified it is intentionally
        // durable. A later item failure must never remove earlier successes.
        var result = try await writeAssets(
            assets,
            to: exportDirectory,
            now: now,
            sessionCreatedAt: sessionCreatedAt,
            signatures: signatures,
            initialManifestEntries: initialManifestEntries,
            onProgress: onProgress
        )
        result.alreadyExportedAssetIDs = Array(alreadyExported)
        return result
    }

    private func writeAssets(
        _ assets: [PHAsset],
        to directoryURL: URL,
        now: Date,
        sessionCreatedAt: Date,
        signatures: [ExternalPhotoExportSessionRecord.AssetSignature],
        initialManifestEntries: [
            ExternalPhotoExportManifest.AssetEntry
        ],
        onProgress: @Sendable @escaping (ExternalPhotoExportProgress) -> Void
    ) async throws -> ExternalPhotoExportResult {
        var manifestEntries = initialManifestEntries
        var exportedAssetIDs = manifestEntries.map(\.localIdentifier)
        let resumedAssetCount = exportedAssetIDs.count
        var completedAssetIDSet = Set(exportedAssetIDs)
        var usedNames = Set(
            manifestEntries
                .flatMap(\.resources)
                .map { $0.exportedFilename.lowercased() }
        )
        var failures: [ExternalPhotoExportItemFailure] = []
        var totalBytes = manifestEntries
            .flatMap(\.resources)
            .reduce(into: Int64(0)) {
                let addition = $0.addingReportingOverflow($1.byteCount)
                $0 = addition.overflow ? .max : addition.partialValue
            }
        var fileCount = manifestEntries.flatMap(\.resources).count
        var processedFileCount = fileCount
        var wasCancelled = false
        let progressEmitter = ExternalPhotoExportProgressEmitter(
            handler: onProgress
        )

        let resourcesByAsset = assets.map { PHAssetResource.assetResources(for: $0) }
        let totalFileCount = resourcesByAsset.reduce(0) { $0 + $1.count }

        assetLoop: for (assetIndex, asset) in assets.enumerated() {
            if completedAssetIDSet.contains(asset.localIdentifier) {
                continue
            }
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            let resources = resourcesByAsset[assetIndex]
            guard !resources.isEmpty else {
                failures.append(
                    ExternalPhotoExportItemFailure(
                        assetID: asset.localIdentifier,
                        filename: nil,
                        message:
                            "This item has no exportable photo or video resources."
                    )
                )
                continue
            }
            let recoverablePrefixBytes = recoverablePartialBytes(
                in: directoryURL
            )
            guard ExternalPhotoExportCapacity.hasCapacity(
                estimatedAssetBytes: max(
                    asset.estimatedFileSize - recoverablePrefixBytes,
                    0
                ),
                availableBytes: availableCapacity(at: directoryURL)
            ) else {
                for remainingAsset in assets[assetIndex...] where
                    !completedAssetIDSet.contains(
                        remainingAsset.localIdentifier
                    ) {
                    failures.append(
                        ExternalPhotoExportItemFailure(
                            assetID: remainingAsset.localIdentifier,
                            filename: nil,
                            message:
                                "The selected drive does not have enough free space to safely continue."
                        )
                    )
                }
                break
            }

            var resourceEntries: [ExternalPhotoExportManifest.AssetEntry.ResourceEntry] = []
            var committedAssetFiles: [URL] = []
            var assetBytes: Int64 = 0
            for (resourceIndex, resource) in resources.enumerated() {
                if Task.isCancelled {
                    committedAssetFiles.forEach {
                        try? fileManager.removeItem(at: $0)
                    }
                    wasCancelled = true
                    break assetLoop
                }
                let filename = ExternalPhotoExportNaming.uniqueFilename(
                    preferredName: resource.originalFilename,
                    assetIndex: assetIndex,
                    resourceIndex: resourceIndex,
                    usedNames: &usedNames
                )
                let finalURL = directoryURL.appendingPathComponent(filename)
                let partialURL = directoryURL.appendingPathComponent(
                    ".\(filename).partial"
                )

                let completedSoFar = processedFileCount
                progressEmitter.send(
                    ExternalPhotoExportProgress(
                        completedFileCount: completedSoFar,
                        totalFileCount: totalFileCount,
                        currentFilename: filename,
                        currentFileFraction: 0
                    ),
                    force: true
                )

                do {
                    let deliveredByteCount = try await write(
                        resource: resource,
                        to: partialURL
                    ) { fraction in
                        progressEmitter.send(
                            ExternalPhotoExportProgress(
                                completedFileCount: completedSoFar,
                                totalFileCount: totalFileCount,
                                currentFilename: filename,
                                currentFileFraction: fraction
                            )
                        )
                    }
                    // PhotoKit's file-writing API has no cancellation handle.
                    // Stop at the first safe boundary, before a completed
                    // partial file is committed to the verified export.
                    try Task.checkCancellation()
                    // Verify the copy against the bytes PhotoKit actually
                    // delivered. Comparing the file to itself across a rename
                    // could not detect a truncated or short-written copy — and
                    // Export & Delete removes the original on the strength of
                    // this check.
                    let byteCount = try verifiedByteCount(at: partialURL)
                    guard byteCount == deliveredByteCount else {
                        throw ExternalPhotoExportError.verificationFailed(filename)
                    }
                    try fileManager.moveItem(at: partialURL, to: finalURL)
                    let finalByteCount = try verifiedByteCount(at: finalURL)
                    guard finalByteCount == deliveredByteCount else {
                        throw ExternalPhotoExportError.verificationFailed(filename)
                    }
                    committedAssetFiles.append(finalURL)
                    let addition = assetBytes.addingReportingOverflow(
                        finalByteCount
                    )
                    assetBytes =
                        addition.overflow ? .max : addition.partialValue
                    processedFileCount += 1
                    progressEmitter.send(
                        ExternalPhotoExportProgress(
                            completedFileCount: processedFileCount,
                            totalFileCount: totalFileCount,
                            currentFilename: nil,
                            currentFileFraction: 0
                        ),
                        force: true
                    )
                    resourceEntries.append(
                        .init(
                            originalFilename: resource.originalFilename,
                            exportedFilename: filename,
                            resourceType: resource.type.rawValue,
                            byteCount: finalByteCount
                        )
                    )
                } catch is CancellationError {
                    try? fileManager.removeItem(at: partialURL)
                    committedAssetFiles.forEach {
                        try? fileManager.removeItem(at: $0)
                    }
                    wasCancelled = true
                    break assetLoop
                } catch {
                    try? fileManager.removeItem(at: partialURL)
                    committedAssetFiles.forEach {
                        try? fileManager.removeItem(at: $0)
                    }
                    // Count the failed resource and the remaining resources as
                    // processed so progress reaches a terminal state while the
                    // next asset can begin.
                    processedFileCount += resources.count - resourceIndex
                    progressEmitter.send(
                        ExternalPhotoExportProgress(
                            completedFileCount: processedFileCount,
                            totalFileCount: totalFileCount,
                            currentFilename: nil,
                            currentFileFraction: 0
                        ),
                        force: true
                    )
                    failures.append(
                        ExternalPhotoExportItemFailure(
                            assetID: asset.localIdentifier,
                            filename: filename,
                            message: error.localizedDescription
                        )
                    )
                    continue assetLoop
                }
            }

            let manifestEntry = ExternalPhotoExportManifest.AssetEntry(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                modificationDate: asset.modificationDate,
                resources: resourceEntries
            )
            manifestEntries.append(manifestEntry)
            exportedAssetIDs.append(asset.localIdentifier)
            completedAssetIDSet.insert(asset.localIdentifier)
            fileCount += resourceEntries.count
            let addition = totalBytes.addingReportingOverflow(assetBytes)
            totalBytes = addition.overflow ? .max : addition.partialValue

            // Checkpoint after every verified asset. If iOS later suspends or
            // terminates the process, completed items and their manifest are
            // already durable on the chosen drive.
            try? writeManifest(
                entries: manifestEntries,
                exportedAt: now,
                to: directoryURL
            )
            try? writeSession(
                signatures: signatures,
                completedAssetIDs: exportedAssetIDs,
                createdAt: sessionCreatedAt,
                isComplete: false,
                to: directoryURL
            )
        }

        try? writeManifest(
            entries: manifestEntries,
            exportedAt: now,
            to: directoryURL
        )
        try? writeSession(
            signatures: signatures,
            completedAssetIDs: exportedAssetIDs,
            createdAt: sessionCreatedAt,
            isComplete: !wasCancelled && failures.isEmpty,
            to: directoryURL
        )

        return ExternalPhotoExportResult(
            directoryURL: directoryURL,
            requestedAssetCount: assets.count,
            resumedAssetCount: resumedAssetCount,
            exportedAssetIDs: exportedAssetIDs,
            failures: failures,
            wasCancelled: wasCancelled,
            fileCount: fileCount,
            processedFileCount: processedFileCount,
            totalPlannedFileCount: totalFileCount,
            totalBytes: totalBytes
        )
    }

    private func writeManifest(
        entries: [ExternalPhotoExportManifest.AssetEntry],
        exportedAt: Date,
        to directoryURL: URL
    ) throws {
        let manifest = ExternalPhotoExportManifest(
            exportedAt: exportedAt,
            assets: entries
        )
        let manifestURL = directoryURL.appendingPathComponent(
            Self.manifestFilename
        )
        let manifestData = try JSONEncoder.photoDuckExportEncoder.encode(
            manifest
        )
        try manifestData.write(to: manifestURL, options: .atomic)
        _ = try verifiedByteCount(at: manifestURL)
    }

    private func writeSession(
        signatures: [ExternalPhotoExportSessionRecord.AssetSignature],
        completedAssetIDs: [String],
        createdAt: Date,
        isComplete: Bool,
        to directoryURL: URL
    ) throws {
        let record = ExternalPhotoExportSessionRecord(
            schemaVersion: ExternalPhotoExportSessionRecord.schemaVersion,
            createdAt: createdAt,
            requestedAssets: signatures,
            completedAssetIDs: completedAssetIDs,
            isComplete: isComplete
        )
        let data = try JSONEncoder.photoDuckExportEncoder.encode(record)
        try data.write(
            to: directoryURL.appendingPathComponent(
                Self.sessionFilename
            ),
            options: .atomic
        )
    }

    private func assetSignatures(
        for assets: [PHAsset]
    ) -> [ExternalPhotoExportSessionRecord.AssetSignature] {
        assets.map {
            ExternalPhotoExportSessionRecord.AssetSignature(
                localIdentifier: $0.localIdentifier,
                modificationDate: $0.modificationDate
            )
        }
    }

    private func resumableExport(
        in parentDirectoryURL: URL,
        matching signatures:
            [ExternalPhotoExportSessionRecord.AssetSignature]
    ) -> RecoveryContext? {
        guard let childURLs = try? fileManager.contentsOfDirectory(
            at: parentDirectoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let recovery = childURLs
            .filter {
                $0.lastPathComponent.hasPrefix("PhotoDuck Export ")
            }
            .compactMap { directoryURL -> RecoveryContext? in
                let sessionURL = directoryURL.appendingPathComponent(
                    Self.sessionFilename
                )
                let manifestURL = directoryURL.appendingPathComponent(
                    Self.manifestFilename
                )
                guard
                    let sessionData = try? Data(contentsOf: sessionURL),
                    let session = try? JSONDecoder.photoDuckExportDecoder.decode(
                        ExternalPhotoExportSessionRecord.self,
                        from: sessionData
                    ),
                    session.schemaVersion
                        == ExternalPhotoExportSessionRecord.schemaVersion,
                    !session.isComplete,
                    session.requestedAssets == signatures
                else {
                    return nil
                }
                let manifestEntries: [
                    ExternalPhotoExportManifest.AssetEntry
                ]
                if let manifestData = try? Data(contentsOf: manifestURL),
                   let manifest =
                    try? JSONDecoder.photoDuckExportDecoder.decode(
                        ExternalPhotoExportManifest.self,
                        from: manifestData
                   ),
                   validateManifest(
                        manifest,
                        in: directoryURL,
                        completedAssetIDs: Set(
                            session.completedAssetIDs
                        )
                   ) {
                    manifestEntries = manifest.assets
                } else if session.completedAssetIDs.isEmpty {
                    manifestEntries = []
                } else {
                    return nil
                }
                return RecoveryContext(
                    directoryURL: directoryURL,
                    session: session,
                    manifestEntries: manifestEntries
                )
            }
            .max {
                $0.session.createdAt < $1.session.createdAt
            }
        if let recovery {
            prepareRecoveryDirectory(
                recovery.directoryURL,
                preserving: recovery.manifestEntries
            )
        }
        return recovery
    }

    private func validateManifest(
        _ manifest: ExternalPhotoExportManifest,
        in directoryURL: URL,
        completedAssetIDs: Set<String>
    ) -> Bool {
        let manifestAssetIDs = Set(
            manifest.assets.map(\.localIdentifier)
        )
        guard completedAssetIDs.isSubset(of: manifestAssetIDs) else {
            return false
        }
        return manifest.assets.allSatisfy { asset in
            !asset.resources.isEmpty
                && asset.resources.allSatisfy { resource in
                    let url = directoryURL.appendingPathComponent(
                        resource.exportedFilename
                    )
                    return (try? verifiedByteCount(at: url))
                        == resource.byteCount
                }
        }
    }

    private func prepareRecoveryDirectory(
        _ directoryURL: URL,
        preserving entries: [
            ExternalPhotoExportManifest.AssetEntry
        ]
    ) {
        let preservedFilenames = Set(
            entries.flatMap(\.resources).map(\.exportedFilename)
        )
        guard let URLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return
        }
        for URL in URLs {
            let filename = URL.lastPathComponent
            guard filename != Self.manifestFilename,
                  filename != Self.sessionFilename,
                  !filename.hasPrefix("."),
                  !preservedFilenames.contains(filename) else {
                continue
            }
            // This is an app-owned export folder. A visible file not present
            // in the last verified manifest was interrupted between rename
            // and checkpoint, so remove it before retrying that resource.
            try? fileManager.removeItem(at: URL)
        }
    }

    private func availableCapacity(at directoryURL: URL) -> Int64? {
        if let values = try? directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity =
            values.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        let attributes = try? fileManager.attributesOfFileSystem(
            forPath: directoryURL.path
        )
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private func recoverablePartialBytes(
        in directoryURL: URL
    ) -> Int64 {
        guard let URLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        ) else {
            return 0
        }
        return URLs.reduce(into: Int64(0)) { total, URL in
            guard URL.lastPathComponent.hasPrefix("."),
                  URL.pathExtension == "partial",
                  let size = try? URL.resourceValues(
                    forKeys: [.fileSizeKey]
                  ).fileSize,
                  size > 0 else {
                return
            }
            let addition = total.addingReportingOverflow(Int64(size))
            total = addition.overflow ? .max : addition.partialValue
        }
    }

    @discardableResult
    private func write(
        resource: PHAssetResource,
        to destinationURL: URL,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> Int64 {
        let existingByteCount: Int64
        if fileManager.fileExists(atPath: destinationURL.path) {
            existingByteCount =
                (try? verifiedByteCount(at: destinationURL)) ?? 0
        } else {
            guard fileManager.createFile(
                atPath: destinationURL.path,
                contents: nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            existingByteCount = 0
        }
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        try fileHandle.seekToEnd()
        let state = ExternalPhotoResourceWriteState(
            fileHandle: fileHandle,
            resourceManager: resourceManager,
            bytesToSkip: existingByteCount
        )
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = onProgress
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard state.install(continuation) else { return }
                let requestID = resourceManager.requestData(
                    for: resource,
                    options: options
                ) { data in
                    state.receive(data)
                } completionHandler: { error in
                    state.complete(error)
                }
                state.setRequestID(requestID)
            }
        } onCancel: {
            state.cancel()
        }
        return state.expectedTotalByteCount
    }

    /// Assets this destination already holds. Every prior export folder keeps a
    /// manifest; an asset counts as already exported only when the recorded
    /// version matches the current one **and** every file it listed is still
    /// present and non-empty. A missing or edited file re-exports.
    func previouslyExportedAssetIDs(
        in parentDirectoryURL: URL,
        matching signatures: [ExternalPhotoExportSessionRecord.AssetSignature]
    ) -> Set<String> {
        guard !signatures.isEmpty else { return [] }
        let wantedVersions = Dictionary(
            signatures.map { ($0.localIdentifier, $0.modificationDate) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let children = try? fileManager.contentsOfDirectory(
            at: parentDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var exported = Set<String>()
        let decoder = JSONDecoder.photoDuckExportDecoder
        for directory in children {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true else {
                continue
            }
            let manifestURL = directory.appendingPathComponent(
                Self.manifestFilename
            )
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(
                    ExternalPhotoExportManifest.self,
                    from: data
                  ) else {
                continue
            }
            for entry in manifest.assets {
                guard let wantedVersion = wantedVersions[entry.localIdentifier],
                      !exported.contains(entry.localIdentifier),
                      entry.modificationDate == wantedVersion,
                      !entry.resources.isEmpty else {
                    continue
                }
                let filesIntact = entry.resources.allSatisfy { resource in
                    let fileURL = directory.appendingPathComponent(
                        resource.exportedFilename
                    )
                    let size = try? verifiedByteCount(at: fileURL)
                    return size == resource.byteCount
                }
                if filesIntact {
                    exported.insert(entry.localIdentifier)
                }
            }
        }
        return exported
    }

    private func verifiedByteCount(at url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey
              ]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0 else {
            throw ExternalPhotoExportError.verificationFailed(
                url.lastPathComponent
            )
        }
        return Int64(fileSize)
    }

    private func uniqueExportDirectory(
        in parentDirectoryURL: URL,
        now: Date
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let baseName = "PhotoDuck Export \(formatter.string(from: now))"
        var candidate = parentDirectoryURL.appendingPathComponent(
            baseName,
            isDirectory: true
        )
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parentDirectoryURL.appendingPathComponent(
                "\(baseName) \(suffix)",
                isDirectory: true
            )
            suffix += 1
        }
        return candidate
    }
}

/// PhotoKit may report hundreds of progress samples for one large resource.
/// Callbacks arrive on an arbitrary serial queue, so this lock protects the
/// coalescing state and caps UI publication at roughly four updates per second
/// while still delivering file boundaries immediately.
private final class ExternalPhotoExportProgressEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (ExternalPhotoExportProgress) -> Void
    private var lastProgress: ExternalPhotoExportProgress?
    private var lastEmissionDate = Date.distantPast

    init(
        handler: @Sendable @escaping (ExternalPhotoExportProgress) -> Void
    ) {
        self.handler = handler
    }

    func send(
        _ progress: ExternalPhotoExportProgress,
        force: Bool = false
    ) {
        let now = Date()
        lock.lock()
        if let lastProgress,
           progress.completedFileCount < lastProgress.completedFileCount {
            lock.unlock()
            return
        }
        let elapsed = now.timeIntervalSince(lastEmissionDate)
        let fractionDelta = abs(
            progress.overallFraction
                - (lastProgress?.overallFraction ?? -1)
        )
        let crossedFileBoundary =
            progress.completedFileCount
                != lastProgress?.completedFileCount
            || progress.currentFilename != lastProgress?.currentFilename
        let shouldEmit =
            force
            || lastProgress == nil
            || crossedFileBoundary
            || (elapsed >= 0.25 && fractionDelta >= 0.002)
        guard shouldEmit else {
            lock.unlock()
            return
        }
        lastProgress = progress
        lastEmissionDate = now
        lock.unlock()
        handler(progress)
    }
}

/// `requestData` delivers bytes on a PhotoKit callback queue while task
/// cancellation can arrive concurrently. Every mutable field and every file
/// handle operation is protected by `lock`; the continuation is consumed
/// exactly once. This narrow unchecked conformance documents that invariant.
final class ExternalPhotoResourceWriteState: @unchecked Sendable {
    private static let writeBufferByteCount = 1_048_576

    private let lock = NSLock()
    private let fileHandle: FileHandle
    private let resourceManager: PHAssetResourceManager
    private var pendingData = Data()
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID = PHInvalidAssetResourceDataRequestID
    private var isFinished = false
    private var remainingBytesToSkip: Int64
    private let resumedPrefixByteCount: Int64
    private var writtenByteCount: Int64 = 0

    init(
        fileHandle: FileHandle,
        resourceManager: PHAssetResourceManager,
        bytesToSkip: Int64 = 0
    ) {
        self.fileHandle = fileHandle
        self.resourceManager = resourceManager
        remainingBytesToSkip = max(bytesToSkip, 0)
        resumedPrefixByteCount = max(bytesToSkip, 0)
    }

    /// Bytes PhotoKit actually delivered for this resource, plus any prefix
    /// already on disk from an interrupted run. The exported file must match
    /// this exactly — that is what makes verification meaningful rather than
    /// comparing a file to itself.
    var expectedTotalByteCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return resumedPrefixByteCount + writtenByteCount
    }

    func install(
        _ continuation: CheckedContinuation<Void, Error>
    ) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()
        if shouldCancel,
           requestID != PHInvalidAssetResourceDataRequestID {
            resourceManager.cancelDataRequest(requestID)
        }
    }

    func receive(_ data: Data) {
        var completion:
            CheckedContinuation<Void, Error>?
        var failure: Error?
        var requestToCancel = PHInvalidAssetResourceDataRequestID

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        do {
            let writableData: Data
            if remainingBytesToSkip > 0 {
                let skippedByteCount = min(
                    remainingBytesToSkip,
                    Int64(data.count)
                )
                remainingBytesToSkip -= skippedByteCount
                writableData = Data(
                    data.dropFirst(Int(skippedByteCount))
                )
            } else {
                writableData = data
            }

            if writableData.isEmpty {
                // The prefix already exists in the interrupted partial file.
            } else if writableData.count >= Self.writeBufferByteCount {
                try flushPendingData()
                try fileHandle.write(contentsOf: writableData)
                writtenByteCount += Int64(writableData.count)
            } else {
                pendingData.append(writableData)
                writtenByteCount += Int64(writableData.count)
                if pendingData.count >= Self.writeBufferByteCount {
                    try flushPendingData()
                }
            }
        } catch {
            failure = error
            isFinished = true
            completion = continuation
            continuation = nil
            requestToCancel = requestID
            pendingData.removeAll(keepingCapacity: false)
            try? fileHandle.close()
        }
        lock.unlock()

        if requestToCancel != PHInvalidAssetResourceDataRequestID {
            resourceManager.cancelDataRequest(requestToCancel)
        }
        if let failure {
            completion?.resume(throwing: failure)
        }
    }

    func complete(_ requestError: Error?) {
        var completion:
            CheckedContinuation<Void, Error>?
        var result: Result<Void, Error>?

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        completion = continuation
        continuation = nil
        if let requestError {
            pendingData.removeAll(keepingCapacity: false)
            try? fileHandle.close()
            result = .failure(requestError)
        } else {
            do {
                guard remainingBytesToSkip == 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try flushPendingData()
                try fileHandle.synchronize()
                try fileHandle.close()
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }
        lock.unlock()

        switch result {
        case .success:
            completion?.resume()
        case .failure(let error):
            completion?.resume(throwing: error)
        case nil:
            break
        }
    }

    func cancel() {
        var completion:
            CheckedContinuation<Void, Error>?
        var requestToCancel = PHInvalidAssetResourceDataRequestID

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        completion = continuation
        continuation = nil
        requestToCancel = requestID
        pendingData.removeAll(keepingCapacity: false)
        try? fileHandle.close()
        lock.unlock()

        if requestToCancel != PHInvalidAssetResourceDataRequestID {
            resourceManager.cancelDataRequest(requestToCancel)
        }
        completion?.resume(throwing: CancellationError())
    }

    /// Called only while `lock` is held.
    private func flushPendingData() throws {
        guard !pendingData.isEmpty else { return }
        try fileHandle.write(contentsOf: pendingData)
        pendingData.removeAll(keepingCapacity: true)
    }
}

private extension JSONEncoder {
    static var photoDuckExportEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var photoDuckExportDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

#if canImport(ActivityKit)
@preconcurrency import ActivityKit

/// Drives the export Live Activity on the Lock Screen / Dynamic Island.
/// The UI itself lives in the PhotoDuckWidgets extension; until that target
/// exists in the project this controller is a safe no-op.
@MainActor
final class ExportLiveActivityController {
    private static let logger = Logger(
        subsystem: "com.photoduck.app",
        category: "ExportLiveActivity"
    )

    private var activity: Any?
    private var lastReportedFraction: Double = -1
    private var lastReportedFileCount: Int = -1
    private var lastReportedTotalFileCount: Int = 0
    private var lastReportedFilename: String?
    private var lastReportedAt = Date.distantPast
    private var isPausedBySystem = false

    func start(destinationName: String, totalFileCount: Int) {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard currentActivity == nil else { return }
        let attributes = PhotoDuckExportActivityAttributes(
            destinationName: destinationName
        )
        let state = PhotoDuckExportActivityAttributes.ContentState(
            completedFileCount: 0,
            totalFileCount: totalFileCount,
            currentFilename: nil,
            overallFraction: 0,
            phase: .exporting
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(5 * 60)
                )
            )
        } catch {
            Self.logger.error(
                "Could not start export Live Activity: \(error.localizedDescription, privacy: .public)"
            )
            activity = nil
        }
        lastReportedFraction = 0
        lastReportedFileCount = 0
        lastReportedTotalFileCount = totalFileCount
        lastReportedFilename = nil
        lastReportedAt = Date()
        isPausedBySystem = false
    }

    func update(with progress: ExternalPhotoExportProgress) async {
        guard #available(iOS 16.2, *) else { return }
        guard !isPausedBySystem else { return }
        // Lock Screen updates are substantially more expensive than the small
        // in-app progress card. Keep file boundaries immediate, but coalesce
        // continuous progress to at most once per second.
        let fraction = progress.overallFraction
        let now = Date()
        let crossedFileBoundary =
            progress.completedFileCount != lastReportedFileCount
            || progress.totalFileCount != lastReportedTotalFileCount
            || progress.currentFilename != lastReportedFilename
        guard crossedFileBoundary
            || (
                now.timeIntervalSince(lastReportedAt) >= 1
                    && abs(fraction - lastReportedFraction) >= 0.01
            ) else {
            return
        }
        lastReportedFraction = fraction
        lastReportedFileCount = progress.completedFileCount
        lastReportedTotalFileCount = progress.totalFileCount
        lastReportedFilename = progress.currentFilename
        lastReportedAt = now
        let state = PhotoDuckExportActivityAttributes.ContentState(
            completedFileCount: progress.completedFileCount,
            totalFileCount: progress.totalFileCount,
            currentFilename: progress.currentFilename,
            overallFraction: fraction,
            phase: .exporting
        )
        await currentActivity?.update(
            ActivityContent(
                state: state,
                staleDate: Date().addingTimeInterval(5 * 60)
            )
        )
    }

    func markPaused() async {
        guard #available(iOS 16.2, *) else { return }
        isPausedBySystem = true
        let state = PhotoDuckExportActivityAttributes.ContentState(
            completedFileCount: max(lastReportedFileCount, 0),
            totalFileCount: lastReportedTotalFileCount,
            currentFilename: nil,
            overallFraction: max(lastReportedFraction, 0),
            phase: .paused
        )
        await currentActivity?.update(
            ActivityContent(state: state, staleDate: nil)
        )
    }

    func resume(with progress: ExternalPhotoExportProgress) async {
        guard #available(iOS 16.2, *) else { return }
        isPausedBySystem = false
        // Force the Dynamic Island back to exporting even when no additional
        // bytes arrived while the process was suspended.
        lastReportedFraction = -1
        lastReportedFileCount = -1
        lastReportedTotalFileCount = -1
        lastReportedFilename = nil
        lastReportedAt = .distantPast
        await update(with: progress)
    }

    func end(
        phase: PhotoDuckExportActivityAttributes.ContentState.Phase,
        completedFileCount: Int,
        totalFileCount: Int
    ) async {
        guard #available(iOS 16.2, *) else { return }
        let state = PhotoDuckExportActivityAttributes.ContentState(
            completedFileCount: completedFileCount,
            totalFileCount: totalFileCount,
            currentFilename: nil,
            overallFraction: phase == .finished ? 1 : lastReportedFraction,
            phase: phase
        )
        let finishedActivity = currentActivity
        activity = nil
        isPausedBySystem = false
        await finishedActivity?.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(.now + 4 * 60 * 60)
        )
    }

    /// An export task cannot survive process termination. End any activity
    /// restored by ActivityKit at the next launch so the Lock Screen never
    /// displays a permanently-running orphan.
    static func endOrphanedActivities() async {
        guard #available(iOS 16.2, *) else { return }
        for orphan in Activity<PhotoDuckExportActivityAttributes>.activities {
            let previous = orphan.content.state
            let state = PhotoDuckExportActivityAttributes.ContentState(
                completedFileCount: previous.completedFileCount,
                totalFileCount: previous.totalFileCount,
                currentFilename: nil,
                overallFraction: previous.overallFraction,
                phase: .cancelled
            )
            await orphan.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }

    @available(iOS 16.2, *)
    private var currentActivity: Activity<PhotoDuckExportActivityAttributes>? {
        activity as? Activity<PhotoDuckExportActivityAttributes>
    }
}
#endif
