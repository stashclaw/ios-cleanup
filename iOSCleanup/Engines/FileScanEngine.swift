import Foundation
import Photos

actor FileScanEngine {

    static let minimumFileSizeBytes: Int64 = 50 * 1024 * 1024  // 50 MB

    func scan() async throws -> [LargeFile] {
        async let photoFiles = largePhotoAssets()
        async let fsFiles = largeFilesystemFiles()

        let all = try await photoFiles + fsFiles
        return all.sorted { $0.byteSize > $1.byteSize }
    }

    private func largePhotoAssets() async throws -> [LargeFile] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }

        let options = PHFetchOptions()
        let result = PHAsset.fetchAssets(with: .video, options: options)

        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        // Also include live photos
        let liveOptions = PHFetchOptions()
        liveOptions.predicate = NSPredicate(format: "mediaSubtype & %d != 0", PHAssetMediaSubtype.photoLive.rawValue)
        let liveResult = PHAsset.fetchAssets(with: .image, options: liveOptions)
        liveResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        return assets.compactMap { asset -> LargeFile? in
            guard let size = fileSize(for: asset), size >= FileScanEngine.minimumFileSizeBytes else { return nil }
            return LargeFile(
                id: UUID(),
                source: .photoLibrary(asset: asset),
                displayName: asset.localIdentifier,
                byteSize: size,
                creationDate: asset.creationDate
            )
        }
    }

    private func largeFilesystemFiles() async throws -> [LargeFile] {
        let searchPaths = [
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.temporaryDirectory,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ].compactMap { $0 }

        var results: [LargeFile] = []

        for base in searchPaths {
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey])
                if resourceValues?.isDirectory == true { continue }
                guard let size = resourceValues?.fileSize, Int64(size) >= FileScanEngine.minimumFileSizeBytes else { continue }

                results.append(LargeFile(
                    id: UUID(),
                    source: .filesystem(url: url),
                    displayName: url.lastPathComponent,
                    byteSize: Int64(size),
                    creationDate: resourceValues?.creationDate
                ))
            }
        }

        return results
    }

    private func fileSize(for asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        // Only use the primary resource to avoid double-counting (original + pairedVideo + fullSizeVideo, etc.)
        let primaryType: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        let primary = resources.first(where: { $0.type == primaryType }) ?? resources.first
        guard let resource = primary else { return nil }
        if let size = resource.value(forKey: "fileSize") as? Int64 { return size }
        if let size = resource.value(forKey: "fileSize") as? Int { return Int64(size) }
        return nil
    }
}
