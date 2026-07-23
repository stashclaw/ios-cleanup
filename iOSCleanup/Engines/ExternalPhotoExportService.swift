import Foundation
import Combine
@preconcurrency import Photos

@MainActor
final class ExportAlbumStore: ObservableObject {
    private static let persistenceKey = "photoduck.export-album.v1"

    @Published private(set) var assetIDs: [String]
    @Published private(set) var assets: [PHAsset] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        assetIDs = defaults.stringArray(forKey: Self.persistenceKey) ?? []
        refreshAssets()
    }

    var count: Int {
        assetIDs.count
    }

    func contains(_ assetID: String) -> Bool {
        assetIDs.contains(assetID)
    }

    func add(_ newAssets: [PHAsset]) {
        guard !newAssets.isEmpty else { return }
        var seen = Set(assetIDs)
        var appendedAssets: [PHAsset] = []
        for asset in newAssets where seen.insert(asset.localIdentifier).inserted {
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
        assetIDs.removeAll { removedIDs.contains($0) }
        assets.removeAll { removedIDs.contains($0.localIdentifier) }
        persist()
    }

    func clear() {
        assetIDs = []
        assets = []
        persist()
    }

    func refreshAssets() {
        guard !assetIDs.isEmpty else {
            assets = []
            return
        }
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: assetIDs,
            options: nil
        )
        var assetsByID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
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
    let assetCount: Int
    let fileCount: Int
    let totalBytes: Int64
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
            return "Select at least one photo to export."
        case .duplicateAssetIdentifiers:
            return "The export selection contains the same photo more than once."
        case .noExportableResources(let assetID):
            return "Photo \(assetID) has no exportable resources. Nothing was deleted."
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
        let resources: [ResourceEntry]
    }

    let exportedAt: Date
    let assets: [AssetEntry]
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
        now: Date = Date()
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

        let exportDirectory = uniqueExportDirectory(
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

        do {
            let result = try await writeAssets(
                assets,
                to: exportDirectory,
                now: now
            )
            return result
        } catch {
            try? fileManager.removeItem(at: exportDirectory)
            throw error
        }
    }

    private func writeAssets(
        _ assets: [PHAsset],
        to directoryURL: URL,
        now: Date
    ) async throws -> ExternalPhotoExportResult {
        var usedNames = Set<String>()
        var manifestEntries: [ExternalPhotoExportManifest.AssetEntry] = []
        var totalBytes: Int64 = 0
        var fileCount = 0

        for (assetIndex, asset) in assets.enumerated() {
            try Task.checkCancellation()
            let resources = PHAssetResource.assetResources(for: asset)
            guard !resources.isEmpty else {
                throw ExternalPhotoExportError.noExportableResources(
                    asset.localIdentifier
                )
            }

            var resourceEntries: [ExternalPhotoExportManifest.AssetEntry.ResourceEntry] = []
            for (resourceIndex, resource) in resources.enumerated() {
                try Task.checkCancellation()
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

                do {
                    try await write(resource: resource, to: partialURL)
                    let byteCount = try verifiedByteCount(at: partialURL)
                    try fileManager.moveItem(at: partialURL, to: finalURL)
                    let finalByteCount = try verifiedByteCount(at: finalURL)
                    guard byteCount == finalByteCount else {
                        throw ExternalPhotoExportError.verificationFailed(filename)
                    }
                    let addition = totalBytes.addingReportingOverflow(finalByteCount)
                    totalBytes = addition.overflow ? .max : addition.partialValue
                    fileCount += 1
                    resourceEntries.append(
                        .init(
                            originalFilename: resource.originalFilename,
                            exportedFilename: filename,
                            resourceType: resource.type.rawValue,
                            byteCount: finalByteCount
                        )
                    )
                } catch let error as ExternalPhotoExportError {
                    try? fileManager.removeItem(at: partialURL)
                    throw error
                } catch {
                    try? fileManager.removeItem(at: partialURL)
                    throw ExternalPhotoExportError.resourceWriteFailed(filename)
                }
            }

            manifestEntries.append(
                .init(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    resources: resourceEntries
                )
            )
        }

        let manifest = ExternalPhotoExportManifest(
            exportedAt: now,
            assets: manifestEntries
        )
        let manifestURL = directoryURL.appendingPathComponent(
            "PhotoDuck Export Manifest.json"
        )
        let manifestData = try JSONEncoder.photoDuckExportEncoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
        _ = try verifiedByteCount(at: manifestURL)

        return ExternalPhotoExportResult(
            directoryURL: directoryURL,
            assetCount: assets.count,
            fileCount: fileCount,
            totalBytes: totalBytes
        )
    }

    private func write(
        resource: PHAssetResource,
        to destinationURL: URL
    ) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            resourceManager.writeData(
                for: resource,
                toFile: destinationURL,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
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

private extension JSONEncoder {
    static var photoDuckExportEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
