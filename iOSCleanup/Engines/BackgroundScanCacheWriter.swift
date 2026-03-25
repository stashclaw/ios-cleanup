import Foundation
import Photos

// MARK: - Cache surrogate types (mirrors HomeViewModel's private types)
// These must be kept in sync with CachedPhotoGroup, CachedLargeFile, and ScanResultsCache
// defined in HomeViewModel.swift.

private struct BGCachedPhotoGroup: Codable {
    let id: UUID
    let localIdentifiers: [String]
    let similarity: Float
    let reasonKey: String
}

private struct BGCachedLargeFile: Codable {
    let id: UUID
    let sourceType: String
    let localIdentifier: String?
    let urlString: String?
    let displayName: String
    let byteSize: Int64
    let creationDate: Date?
}

/// Mirrors the ScanResultsCache in HomeViewModel. Fields must remain identical so
/// HomeViewModel can decode what we write here.
private struct BGScanResultsCache: Codable {
    let version: Int
    let savedAt: Date
    let photoGroups: [BGCachedPhotoGroup]
    let largeFiles: [BGCachedLargeFile]
    var blurPhotoIds: [String]
    var screenshotPhotoIds: [String]
    var largePhotoIds: [String]
    var largePhotoSizes: [Int64]

    // Custom init provides defaults for optional fields so old cache files decode cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version            = try c.decode(Int.self,                   forKey: .version)
        savedAt            = try c.decode(Date.self,                  forKey: .savedAt)
        photoGroups        = try c.decode([BGCachedPhotoGroup].self,  forKey: .photoGroups)
        largeFiles         = try c.decode([BGCachedLargeFile].self,   forKey: .largeFiles)
        blurPhotoIds       = (try? c.decode([String].self,            forKey: .blurPhotoIds))       ?? []
        screenshotPhotoIds = (try? c.decode([String].self,            forKey: .screenshotPhotoIds)) ?? []
        largePhotoIds      = (try? c.decode([String].self,            forKey: .largePhotoIds))      ?? []
        largePhotoSizes    = (try? c.decode([Int64].self,             forKey: .largePhotoSizes))    ?? []
    }

    init(version: Int, savedAt: Date, photoGroups: [BGCachedPhotoGroup],
         largeFiles: [BGCachedLargeFile], blurPhotoIds: [String], screenshotPhotoIds: [String],
         largePhotoIds: [String], largePhotoSizes: [Int64]) {
        self.version            = version
        self.savedAt            = savedAt
        self.photoGroups        = photoGroups
        self.largeFiles         = largeFiles
        self.blurPhotoIds       = blurPhotoIds
        self.screenshotPhotoIds = screenshotPhotoIds
        self.largePhotoIds      = largePhotoIds
        self.largePhotoSizes    = largePhotoSizes
    }
}

// MARK: - BackgroundScanCacheWriter

/// Runs a lightweight background scan and updates the existing ScanResultsCache
/// that HomeViewModel reads on launch. This means the app shows results instantly
/// on the next foreground open without requiring a manual scan.
actor BackgroundScanCacheWriter {

    // MARK: - Cache file URL (must match HomeViewModel.cacheURL)

    private var cacheURL: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("photoduck_scan_v1.json")
    }

    // MARK: - Entry point

    func run() async {
        guard !Task.isCancelled else { return }

        // Run duplicate hash scan (fastest, most impactful)
        let duplicateGroups = await runDuplicateScan()

        guard !Task.isCancelled else { return }

        // Run blur scan
        let blurIds = await runBlurScan()

        guard !Task.isCancelled else { return }

        // Merge new results into existing cache (preserving large files, screenshots, etc.)
        await mergeAndSave(duplicateGroups: duplicateGroups, blurPhotoIds: blurIds)
    }

    // MARK: - Duplicate scan

    private func runDuplicateScan() async -> [BGCachedPhotoGroup] {
        var groups: [BGCachedPhotoGroup] = []
        let engine = DuplicateHashEngine()
        do {
            for try await event in engine.scan(addedAfter: nil) {
                guard !Task.isCancelled else { break }
                switch event {
                case .progress:
                    break
                case .duplicatesFound(let photoGroups):
                    let cached = photoGroups.map { group in
                        BGCachedPhotoGroup(
                            id: group.id,
                            localIdentifiers: group.assets.map(\.localIdentifier),
                            similarity: group.similarity,
                            reasonKey: group.reason.cacheKey
                        )
                    }
                    groups.append(contentsOf: cached)
                }
            }
        } catch {
            // Non-fatal — return whatever we collected
        }
        return groups
    }

    // MARK: - Blur scan

    private func runBlurScan() async -> [String] {
        var blurIds: [String] = []
        let engine = BlurScanEngine()
        do {
            for try await event in engine.scan(addedAfter: nil) {
                guard !Task.isCancelled else { break }
                switch event {
                case .progress:
                    break
                case .blurryPhotosFound(let assets):
                    blurIds.append(contentsOf: assets.map(\.localIdentifier))
                }
            }
        } catch {
            // Non-fatal — return whatever we collected
        }
        return blurIds
    }

    // MARK: - Cache merge + write

    private func mergeAndSave(duplicateGroups: [BGCachedPhotoGroup], blurPhotoIds: [String]) async {
        // Load existing cache so we preserve fields we didn't scan (largeFiles, screenshots, etc.)
        let existing = loadExistingCache()
        let now = Date()

        // Deduplicate incoming duplicate groups against any already-cached groups.
        // Priority: exactDuplicate > nearDuplicate > burstShot > visuallySimilar
        var canonical: [Set<String>: BGCachedPhotoGroup] = [:]

        // Seed with existing cached photo groups
        for group in (existing?.photoGroups ?? []) {
            let key = Set(group.localIdentifiers)
            canonical[key] = group
        }

        // Merge new duplicate groups (higher-priority reason wins)
        for group in duplicateGroups {
            let key = Set(group.localIdentifiers)
            if let existing = canonical[key] {
                if reasonPriority(group.reasonKey) > reasonPriority(existing.reasonKey) {
                    canonical[key] = group
                }
            } else {
                canonical[key] = group
            }
        }

        let mergedGroups = Array(canonical.values)

        // For blur: merge new IDs with existing, deduplicating
        var mergedBlurIds: [String]
        if let existingBlur = existing?.blurPhotoIds, !existingBlur.isEmpty {
            let existingSet = Set(existingBlur)
            let newOnly = blurPhotoIds.filter { !existingSet.contains($0) }
            mergedBlurIds = existingBlur + newOnly
        } else {
            mergedBlurIds = blurPhotoIds
        }

        let updatedCache = BGScanResultsCache(
            version: 1,
            savedAt: now,
            photoGroups: mergedGroups,
            largeFiles: existing?.largeFiles ?? [],
            blurPhotoIds: mergedBlurIds,
            screenshotPhotoIds: existing?.screenshotPhotoIds ?? [],
            largePhotoIds: existing?.largePhotoIds ?? [],
            largePhotoSizes: existing?.largePhotoSizes ?? []
        )

        do {
            let data = try JSONEncoder().encode(updatedCache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Non-fatal: HomeViewModel will rescan on next foreground launch
        }
    }

    // MARK: - Helpers

    private func loadExistingCache() -> BGScanResultsCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(BGScanResultsCache.self, from: data)
    }

    private func reasonPriority(_ key: String) -> Int {
        switch key {
        case "exactDuplicate":  return 3
        case "nearDuplicate":   return 2
        case "burstShot":       return 1
        case "visuallySimilar": return 0
        default:                return -1
        }
    }
}

// MARK: - PhotoGroup.SimilarityReason cacheKey (mirrors HomeViewModel's private extension)

private extension PhotoGroup.SimilarityReason {
    var cacheKey: String {
        switch self {
        case .nearDuplicate:   return "nearDuplicate"
        case .exactDuplicate:  return "exactDuplicate"
        case .visuallySimilar: return "visuallySimilar"
        case .burstShot:       return "burstShot"
        }
    }
}
