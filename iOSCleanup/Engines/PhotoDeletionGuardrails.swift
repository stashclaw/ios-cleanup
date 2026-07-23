import Photos

enum PhotoDeletionGuardrailError: Error, LocalizedError, Equatable {
    case missingKeeperAssetID
    case emptyDeleteCandidateList
    case keeperIncludedInDeleteCandidates
    case duplicateDeleteCandidateIDs
    case automaticActionNotAllowed
    case visuallySimilarReviewOnly
    case confidenceTooLow
    case blockerFlagsPresent
    case keeperNotInGroup
    case deleteCandidateNotInGroup
    case wouldDeleteEntireGroup
    case crossGroupKeeperConflict
    case duplicateDeleteAcrossGroups
    case invalidManualSelection

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
        case .automaticActionNotAllowed:
            return "This photo group is available for review only."
        case .visuallySimilarReviewOnly:
            return "Visually similar photos must be reviewed manually."
        case .confidenceTooLow:
            return "Automatic cleanup requires a high-confidence group."
        case .blockerFlagsPresent:
            return "Automatic cleanup is blocked by unresolved similarity warnings."
        case .keeperNotInGroup:
            return "The recommended keeper is no longer part of this photo group."
        case .deleteCandidateNotInGroup:
            return "A delete candidate is no longer part of this photo group."
        case .wouldDeleteEntireGroup:
            return "A cleanup plan must leave at least one photo in the group."
        case .crossGroupKeeperConflict:
            return "A photo recommended as a keeper in one group cannot be deleted by another."
        case .duplicateDeleteAcrossGroups:
            return "The same photo appears in more than one cleanup plan."
        case .invalidManualSelection:
            return "The selected photos are not a safe subset of this group."
        }
    }
}

enum PhotoDeletionGuardrails {
    static func validate(group: PhotoGroup) throws {
        try validate(
            keeperAssetID: group.keeperAssetID,
            deleteCandidateIDs: group.deleteCandidateIDs,
            assetIDs: Set(group.assets.map(\.localIdentifier)),
            recommendedAction: group.recommendedAction,
            reason: group.reason,
            confidence: group.groupConfidence,
            blockerFlags: group.blockerFlags
        )
    }

    static func validate(keeperAssetID: String?, deleteCandidateIDs: [String]) throws {
        try validateIdentifiers(
            keeperAssetID: keeperAssetID,
            deleteCandidateIDs: deleteCandidateIDs
        )
    }

    static func validate(
        keeperAssetID: String?,
        deleteCandidateIDs: [String],
        assetIDs: Set<String>,
        recommendedAction: SimilarRecommendedAction?,
        reason: PhotoGroup.SimilarityReason,
        confidence: SimilarGroupConfidence,
        blockerFlags: [BlockerFlag]
    ) throws {
        guard recommendedAction == .keepBestTrashRest else {
            throw PhotoDeletionGuardrailError.automaticActionNotAllowed
        }
        guard reason != .visuallySimilar else {
            throw PhotoDeletionGuardrailError.visuallySimilarReviewOnly
        }
        guard confidence == .high else {
            throw PhotoDeletionGuardrailError.confidenceTooLow
        }
        guard blockerFlags.isEmpty else {
            throw PhotoDeletionGuardrailError.blockerFlagsPresent
        }

        try validateIdentifiers(
            keeperAssetID: keeperAssetID,
            deleteCandidateIDs: deleteCandidateIDs
        )

        guard let keeperAssetID, assetIDs.contains(keeperAssetID) else {
            throw PhotoDeletionGuardrailError.keeperNotInGroup
        }
        guard Set(deleteCandidateIDs).isSubset(of: assetIDs) else {
            throw PhotoDeletionGuardrailError.deleteCandidateNotInGroup
        }
        guard deleteCandidateIDs.count < assetIDs.count else {
            throw PhotoDeletionGuardrailError.wouldDeleteEntireGroup
        }
    }

    static func validate(groups: [PhotoGroup]) throws {
        for group in groups {
            try validate(group: group)
        }

        try validateCrossGroup(
            keeperAssetIDs: groups.compactMap(\.keeperAssetID),
            deleteCandidateIDsByGroup: groups.map(\.deleteCandidateIDs)
        )
    }

    static func validateCrossGroup(
        keeperAssetIDs: [String],
        deleteCandidateIDsByGroup: [[String]]
    ) throws {
        let keeperIDs = Set(keeperAssetIDs)
        var deleteIDs = Set<String>()
        for groupDeleteIDs in deleteCandidateIDsByGroup {
            for deleteCandidateID in groupDeleteIDs {
                guard deleteIDs.insert(deleteCandidateID).inserted else {
                    throw PhotoDeletionGuardrailError.duplicateDeleteAcrossGroups
                }
            }
        }

        guard keeperIDs.isDisjoint(with: deleteIDs) else {
            throw PhotoDeletionGuardrailError.crossGroupKeeperConflict
        }
    }

    static func validateManualSelection(assetIDs: Set<String>, in group: PhotoGroup) throws {
        try validateManualSelection(
            assetIDs: assetIDs,
            groupAssetIDs: Set(group.assets.map(\.localIdentifier))
        )
    }

    static func validateManualSelection(
        assetIDs: Set<String>,
        groupAssetIDs: Set<String>
    ) throws {
        guard !assetIDs.isEmpty,
              assetIDs.isSubset(of: groupAssetIDs),
              assetIDs.count < groupAssetIDs.count else {
            throw PhotoDeletionGuardrailError.invalidManualSelection
        }
    }

    private static func validateIdentifiers(
        keeperAssetID: String?,
        deleteCandidateIDs: [String]
    ) throws {
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
        return group.deleteCandidateIDs
    }

    static func deleteAssets(in group: PhotoGroup) throws -> [PHAsset] {
        let deleteIDs = Set(try deleteAssetIDs(in: group))
        return group.assets.filter { deleteIDs.contains($0.localIdentifier) }
    }
}
