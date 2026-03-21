import Photos

enum PhotoDeletionGuardrailError: Error, LocalizedError, Equatable {
    case missingKeeperAssetID
    case emptyDeleteCandidateList
    case keeperIncludedInDeleteCandidates
    case duplicateDeleteCandidateIDs

    var errorDescription: String? {
        switch self {
        case .missingKeeperAssetID:
            return "Cannot delete a photo group without an explicit keeper."
        case .emptyDeleteCandidateList:
            return "No delete candidates were supplied for this photo group."
        case .keeperIncludedInDeleteCandidates:
            return "Delete candidates include the keeper asset."
        case .duplicateDeleteCandidateIDs:
            return "Delete candidates contain duplicate asset identifiers."
        }
    }
}

enum PhotoDeletionGuardrails {
    static func validate(group: PhotoGroup) throws {
        try validate(keeperAssetID: group.keeperAssetID, deleteCandidateIDs: group.deleteCandidateIDs)
    }

    static func validate(keeperAssetID: String?, deleteCandidateIDs: [String]) throws {
        guard let keeperAssetID else { throw PhotoDeletionGuardrailError.missingKeeperAssetID }
        guard !deleteCandidateIDs.isEmpty else { throw PhotoDeletionGuardrailError.emptyDeleteCandidateList }
        guard Set(deleteCandidateIDs).count == deleteCandidateIDs.count else {
            throw PhotoDeletionGuardrailError.duplicateDeleteCandidateIDs
        }
        guard !deleteCandidateIDs.contains(keeperAssetID) else {
            throw PhotoDeletionGuardrailError.keeperIncludedInDeleteCandidates
        }
    }

    static func deleteAssetIDs(in group: PhotoGroup) throws -> [String] {
        try validate(group: group)
        if !group.deleteCandidateIDs.isEmpty {
            return group.deleteCandidateIDs
        }
        guard let keeperAssetID = group.keeperAssetID else {
            throw PhotoDeletionGuardrailError.missingKeeperAssetID
        }
        return group.assets.map(\.localIdentifier).filter { $0 != keeperAssetID }
    }

    static func deleteAssets(in group: PhotoGroup) throws -> [PHAsset] {
        let deleteIDs = Set(try deleteAssetIDs(in: group))
        return group.assets.filter { deleteIDs.contains($0.localIdentifier) }
    }
}
