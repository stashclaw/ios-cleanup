import Foundation

enum PhotoTrainingExampleBuilder {
    static func makeRows<S: Sequence>(from events: S) -> [PhotoTrainingExportRow] where S.Element == PhotoReviewFeedbackEvent {
        var rows: [PhotoTrainingExportRow] = []
        for event in events {
            rows.append(contentsOf: makeRows(from: event))
        }
        return rows
    }

    static func makeRows(from event: PhotoReviewFeedbackEvent) -> [PhotoTrainingExportRow] {
        let sortedAssets = event.assets.sorted { $0.localIdentifier < $1.localIdentifier }
        var rows: [PhotoTrainingExportRow] = []

        for asset in sortedAssets {
            rows.append(
                makeAssetPreferenceRow(event: event, asset: asset)
            )
        }

        rows.append(makeGroupOutcomeRow(event: event))

        if sortedAssets.count >= 2 || sortedAssets.contains(where: { $0.rankingScore != nil }) {
            rows.append(contentsOf: sortedAssets.map { asset in
                makeKeeperRankingRow(event: event, asset: asset)
            })
        }

        return rows
    }

    private static func makeAssetPreferenceRow(
        event: PhotoReviewFeedbackEvent,
        asset: PhotoReviewFeedbackAsset
    ) -> PhotoTrainingExportRow {
        PhotoTrainingExportRow(
            id: rowID(event: event, kind: .assetPreference, assetID: asset.localIdentifier),
            eventID: event.id,
            kind: .assetPreference,
            timestamp: event.timestamp,
            groupID: event.groupID,
            assetID: asset.localIdentifier,
            assetRole: asset.role,
            outcomeLabel: outcomeLabel(for: event, asset: asset),
            bucket: event.bucket,
            groupType: event.groupType,
            confidence: event.confidence,
            suggestedAction: event.suggestedAction,
            recommendationAccepted: event.recommendationAccepted,
            keeperAssetID: event.finalKeeperAssetID ?? event.suggestedKeeperAssetID,
            rankingScore: asset.rankingScore,
            similarityToKeeper: asset.similarityToKeeper,
            policyVersion: event.policyVersion,
            modelVersion: event.modelVersion,
            featureSchemaVersion: event.featureSchemaVersion,
            featureVector: featureVector(for: asset)
        )
    }

    private static func makeGroupOutcomeRow(event: PhotoReviewFeedbackEvent) -> PhotoTrainingExportRow {
        PhotoTrainingExportRow(
            id: rowID(event: event, kind: .groupOutcome, assetID: nil),
            eventID: event.id,
            kind: .groupOutcome,
            timestamp: event.timestamp,
            groupID: event.groupID,
            assetID: nil,
            assetRole: .unknown,
            outcomeLabel: outcomeLabel(for: event),
            bucket: event.bucket,
            groupType: event.groupType,
            confidence: event.confidence,
            suggestedAction: event.suggestedAction,
            recommendationAccepted: event.recommendationAccepted,
            keeperAssetID: event.finalKeeperAssetID ?? event.suggestedKeeperAssetID,
            rankingScore: nil,
            similarityToKeeper: nil,
            policyVersion: event.policyVersion,
            modelVersion: event.modelVersion,
            featureSchemaVersion: event.featureSchemaVersion,
            featureVector: nil
        )
    }

    private static func makeKeeperRankingRow(
        event: PhotoReviewFeedbackEvent,
        asset: PhotoReviewFeedbackAsset
    ) -> PhotoTrainingExportRow {
        PhotoTrainingExportRow(
            id: rowID(event: event, kind: .keeperRanking, assetID: asset.localIdentifier),
            eventID: event.id,
            kind: .keeperRanking,
            timestamp: event.timestamp,
            groupID: event.groupID,
            assetID: asset.localIdentifier,
            assetRole: asset.role,
            outcomeLabel: rankingLabel(for: event, asset: asset),
            bucket: event.bucket,
            groupType: event.groupType,
            confidence: event.confidence,
            suggestedAction: event.suggestedAction,
            recommendationAccepted: event.recommendationAccepted,
            keeperAssetID: event.finalKeeperAssetID ?? event.suggestedKeeperAssetID,
            rankingScore: asset.rankingScore,
            similarityToKeeper: asset.similarityToKeeper,
            policyVersion: event.policyVersion,
            modelVersion: event.modelVersion,
            featureSchemaVersion: event.featureSchemaVersion,
            featureVector: featureVector(for: asset)
        )
    }

    private static func outcomeLabel(for event: PhotoReviewFeedbackEvent, asset: PhotoReviewFeedbackAsset? = nil) -> String {
        switch event.kind {
        case .keepBest:
            return asset?.role == .finalKeeper ? "keep_best_keeper" : "keep_best_candidate"
        case .keeperOverride:
            return asset?.role == .finalKeeper ? "override_keeper" : "override_candidate"
        case .deleteSelected:
            return asset?.role == .deleted ? "deleted" : "kept"
        case .skipGroup:
            return "skipped"
        case .swipeKeep:
            return "swipe_keep"
        case .swipeDelete:
            return "swipe_delete"
        case .restoreUndo:
            return "restored"
        case .editPreferenceSignal:
            return "edit_signal"
        }
    }

    private static func rankingLabel(for event: PhotoReviewFeedbackEvent, asset: PhotoReviewFeedbackAsset) -> String {
        if asset.localIdentifier == event.finalKeeperAssetID {
            return "keeper"
        }
        if asset.localIdentifier == event.suggestedKeeperAssetID {
            return "suggested_keeper"
        }
        return "candidate"
    }

    private static func featureVector(for asset: PhotoReviewFeedbackAsset?) -> PhotoTrainingFeatureVector {
        guard let asset else {
            return PhotoTrainingFeatureVector(
                pixelWidth: 1,
                pixelHeight: 1,
                isFavorite: nil,
                isEdited: nil,
                isScreenshot: false,
                burstIdentifierPresent: false,
                similarityToKeeper: nil,
                rankingScore: nil,
                flags: []
            )
        }

        return PhotoTrainingFeatureVector(
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            isEdited: asset.isEdited,
            isScreenshot: asset.isScreenshot ?? false,
            burstIdentifierPresent: asset.burstIdentifier != nil,
            similarityToKeeper: asset.similarityToKeeper,
            rankingScore: asset.rankingScore,
            flags: asset.flags
        )
    }

    private static func rowID(event: PhotoReviewFeedbackEvent, kind: PhotoTrainingRowKind, assetID: String?) -> String {
        let assetComponent = assetID ?? "group"
        return "\(event.id.uuidString):\(kind.rawValue):\(assetComponent)"
    }
}
