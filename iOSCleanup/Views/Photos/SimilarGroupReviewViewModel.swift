import Foundation
import Photos

@MainActor
final class SimilarGroupReviewViewModel: ObservableObject {
    let groups: [PhotoGroup]
    let coordinator: SimilarPhotoReviewCoordinator

    @Published var currentGroupIndex: Int
    @Published var currentPhotoIndex: Int = 0
    @Published var selectedTrashPhotoIDs = Set<String>()
    @Published var protectedPhotoIDs = Set<String>()
    @Published var viewedPhotoIDs = Set<String>()
    @Published var showExplanationSheet = false
    @Published var selectedOverridePhotoID: String?
    @Published var lastActionSummary: String = ""
    @Published var recentTrashAction: SimilarTrashAction?
    @Published var isBusy = false
    @Published var reviewStateByGroupID: [UUID: SimilarReviewState] = [:]

    init(groups: [PhotoGroup], startGroupID: UUID? = nil, coordinator: SimilarPhotoReviewCoordinator = SimilarPhotoReviewCoordinator()) {
        self.groups = groups
        self.coordinator = coordinator
        if let startGroupID, let index = groups.firstIndex(where: { $0.id == startGroupID }) {
            currentGroupIndex = index
        } else {
            currentGroupIndex = 0
        }

        if let currentPhoto = currentGroup?.candidates.first {
            selectedOverridePhotoID = currentGroup?.keeperAssetID ?? currentPhoto.photoId
        }
    }

    var totalGroups: Int { groups.count }

    var currentGroup: PhotoGroup? {
        guard currentGroupIndex < groups.count else { return nil }
        return groups[currentGroupIndex]
    }

    var currentGroupPositionLabel: String {
        guard totalGroups > 0 else { return "0 of 0" }
        return "\(currentGroupIndex + 1) of \(totalGroups)"
    }

    var currentGroupSummaryLabel: String {
        guard let group = currentGroup else { return "No similar photos" }
        return group.photoCount == 1 ? "1 similar photo" : "\(group.photoCount) similar photos"
    }

    var currentGroupContextLabel: String {
        guard let group = currentGroup else { return "" }
        return "\(group.reason.displayName) · \(group.groupType.displayName) · \(group.groupConfidence.displayName)"
    }

    var currentPhotoCount: Int {
        currentGroup?.photoCount ?? 0
    }

    var currentReviewableCount: Int {
        currentGroup?.photoCount ?? 0
    }

    var currentBestShot: SimilarPhotoCandidate? {
        guard let group = currentGroup else { return nil }
        if let keeperAssetID = group.keeperAssetID {
            return group.candidates.first(where: { $0.photoId == keeperAssetID })
        }
        return nil
    }

    var selectedKeeperCandidate: SimilarPhotoCandidate? {
        guard let group = currentGroup else { return nil }
        if let selectedOverridePhotoID,
           let candidate = group.candidates.first(where: { $0.photoId == selectedOverridePhotoID }) {
            return candidate
        }
        return currentBestShot ?? group.candidates.first
    }

    var currentFocusedPhoto: SimilarPhotoCandidate? {
        guard let group = currentGroup, currentPhotoIndex < group.candidates.count else { return nil }
        return group.candidates[currentPhotoIndex]
    }

    var confidenceLabel: String {
        currentGroup?.groupConfidence.displayName ?? "Needs review"
    }

    var confidenceDescription: String {
        switch currentGroup?.groupConfidence ?? .medium {
        case .high: return "Safe to keep the best shot and duck the rest."
        case .medium: return "Recommended best shot, but inspect before trashing."
        case .low: return "Recommended choice only. Review manually before deleting."
        }
    }

    var recommendationTitle: String {
        selectedKeeperCandidate?.photoId == currentBestShot?.photoId ? "Recommended keeper" : "Selected keeper"
    }

    var recommendationSubtitle: String {
        guard let selectedKeeperCandidate else { return "Tap a card to choose the keeper." }
        if selectedKeeperCandidate.photoId == currentBestShot?.photoId {
            return "Recommended by the scan."
        }
        return "Manually selected for this review."
    }

    var selectedKeeperReasons: [String] {
        selectedKeeperCandidate?.bestShotReasons ?? []
    }

    var trustNote: String {
        "Review manually before moving anything to trash."
    }

    var currentGroupReclaimableBytes: Int64 {
        currentGroup?.reclaimableBytes ?? 0
    }

    var currentTrashCount: Int {
        selectedTrashPhotoIDs.count
    }

    var currentKeepCount: Int {
        max(currentPhotoCount - currentTrashCount, 0)
    }

    var actionTitle: String {
        if currentGroup?.groupConfidence == .high {
            return "Move \(currentTrashCount) to Trash"
        }
        if currentTrashCount > 0 {
            return "Move \(currentTrashCount) to Trash"
        }
        return "Keep Best"
    }

    var currentBestShotReasons: [String] {
        currentBestShot?.bestShotReasons ?? []
    }

    var currentIssueFlags: [IssueFlag] {
        currentFocusedPhoto?.issueFlags ?? []
    }

    var currentReviewState: SimilarReviewState {
        guard let id = currentGroup?.id else { return .unreviewed }
        return reviewStateByGroupID[id] ?? .unreviewed
    }

    func setFocusedPhoto(index: Int) {
        guard let group = currentGroup, group.candidates.indices.contains(index) else { return }
        currentPhotoIndex = index
        selectedOverridePhotoID = group.candidates[index].photoId
        markViewed(photoID: group.candidates[index].photoId)
    }

    func moveToNextPhoto() {
        guard let group = currentGroup else { return }
        guard let nextIndex = nextReviewablePhotoIndex(after: currentPhotoIndex, in: group) else { return }
        setFocusedPhoto(index: nextIndex)
    }

    func moveToPreviousPhoto() {
        guard let group = currentGroup else { return }
        guard let previousIndex = previousReviewablePhotoIndex(before: currentPhotoIndex, in: group) else { return }
        setFocusedPhoto(index: previousIndex)
    }

    func markViewed(photoID: String) {
        viewedPhotoIDs.insert(photoID)
    }

    func toggleTrashSelection(for photoID: String) {
        guard !protectedPhotoIDs.contains(photoID) else { return }
        guard isDeleteCandidate(photoID) else { return }
        let isFocusedPhoto = currentFocusedPhoto?.photoId == photoID
        let wasSelected = selectedTrashPhotoIDs.contains(photoID)
        if selectedTrashPhotoIDs.contains(photoID) {
            selectedTrashPhotoIDs.remove(photoID)
        } else {
            selectedTrashPhotoIDs.insert(photoID)
        }
        updateCurrentOverride()
        if isFocusedPhoto, !wasSelected {
            advanceAfterDuckingCurrentPhoto()
        }
    }

    func setProtected(photoID: String, protected: Bool) {
        guard isCurrentAsset(photoID) else { return }
        if protected {
            protectedPhotoIDs.insert(photoID)
            selectedTrashPhotoIDs.remove(photoID)
        } else {
            protectedPhotoIDs.remove(photoID)
        }
        updateCurrentOverride()
    }

    func keepBest() {
        guard let group = currentGroup else { return }
        guard let keeperAssetID = currentKeeperAssetID else { return }
        selectedTrashPhotoIDs.removeAll()
        guard !group.deleteCandidateIDs.isEmpty else {
            lastActionSummary = "Best shot selected"
            reviewStateByGroupID[group.id] = .inProgress
            showExplanationSheet = false
            updateCurrentOverride()
            Task {
                await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                    group: group,
                    kind: .keepBest,
                    stage: group.groupConfidence == .high ? .committed : .provisional,
                    selectedKeeperID: currentSelectedKeeperAssetID,
                    keptAssetIDs: [currentSelectedKeeperAssetID ?? keeperAssetID].compactMap { $0 },
                    recommendationAccepted: currentSelectedKeeperAssetID == group.keeperAssetID,
                    note: lastActionSummary
                )
            }
            return
        }
        for photoID in group.deleteCandidateIDs where photoID != keeperAssetID && !protectedPhotoIDs.contains(photoID) {
            selectedTrashPhotoIDs.insert(photoID)
        }
        lastActionSummary = "Best shot selected"
        reviewStateByGroupID[group.id] = .inProgress
        showExplanationSheet = false
        updateCurrentOverride()
        Task {
            await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                group: group,
                kind: .keepBest,
                stage: group.groupConfidence == .high ? .committed : .provisional,
                selectedKeeperID: currentSelectedKeeperAssetID,
                keptAssetIDs: [currentSelectedKeeperAssetID ?? keeperAssetID].compactMap { $0 },
                recommendationAccepted: currentSelectedKeeperAssetID == group.keeperAssetID,
                note: lastActionSummary
            )
        }
    }

    func reviewLater() {
        guard let group = currentGroup else { return }
        reviewStateByGroupID[group.id] = .reviewLater
        coordinator.markReviewed(groupID: group.id)
        lastActionSummary = "Review later"
        advanceGroup()
    }

    func skipGroup() {
        guard let group = currentGroup else { return }
        reviewStateByGroupID[group.id] = .skipped
        coordinator.markReviewed(groupID: group.id)
        selectedTrashPhotoIDs.removeAll()
        lastActionSummary = "Skipped group"
        Task {
            await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                group: group,
                kind: .skipGroup,
                stage: .committed,
                selectedKeeperID: currentSelectedKeeperAssetID,
                skipped: true,
                recommendationAccepted: nil,
                note: lastActionSummary
            )
        }
        advanceGroup()
    }

    func resolveTrashAction() {
        guard let group = currentGroup else { return }
        let selectedIDs = Set(selectedTrashPhotoIDs).subtracting([currentKeeperAssetID].compactMap { $0 })
        let movedCount = selectedIDs.count
        let reclaimedBytes = selectedIDs.reduce(into: Int64(0)) { acc, id in
            guard let asset = group.assets.first(where: { $0.localIdentifier == id }) else { return }
            acc += asset.estimatedFileSize
        }

        let summary: String
        if movedCount == 0 {
            summary = "Kept the best shot"
        } else {
            summary = "Moved \(movedCount) to Trash"
        }

        coordinator.registerTrashAction(
            groupID: group.id,
            movedCount: movedCount,
            reclaimedBytes: reclaimedBytes,
            summary: summary
        )
        recentTrashAction = coordinator.recentTrashAction
        reviewStateByGroupID[group.id] = .resolved
        lastActionSummary = summary
        Task {
            await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                group: group,
                kind: .deleteSelected,
                stage: .committed,
                selectedKeeperID: currentSelectedKeeperAssetID,
                deletedAssetIDs: Array(selectedIDs),
                keptAssetIDs: [currentSelectedKeeperAssetID].compactMap { $0 },
                recommendationAccepted: selectedIDs == Set(group.deleteCandidateIDs),
                note: lastActionSummary
            )
        }
        advanceGroup()
    }

    func overrideBestShot(photoID: String) {
        guard let group = currentGroup, group.candidates.contains(where: { $0.photoId == photoID }) else { return }
        selectedOverridePhotoID = photoID
        selectedTrashPhotoIDs.remove(photoID)
        guard !group.deleteCandidateIDs.isEmpty else {
            lastActionSummary = "Best shot updated"
            Task {
                await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                    group: group,
                    kind: .keeperOverride,
                    stage: .committed,
                    selectedKeeperID: photoID,
                    keptAssetIDs: [photoID],
                    recommendationAccepted: photoID == group.keeperAssetID,
                    note: lastActionSummary
                )
            }
            return
        }
        for candidateID in group.deleteCandidateIDs where candidateID != photoID && !protectedPhotoIDs.contains(candidateID) {
            selectedTrashPhotoIDs.insert(candidateID)
        }
        lastActionSummary = "Best shot updated"
        Task {
            await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                group: group,
                kind: .keeperOverride,
                stage: .committed,
                selectedKeeperID: photoID,
                keptAssetIDs: [photoID],
                recommendationAccepted: photoID == group.keeperAssetID,
                note: lastActionSummary
            )
        }
    }

    func undoLastTrashSelection() {
        selectedTrashPhotoIDs.removeAll()
        recentTrashAction = nil
        coordinator.clearUndo()
        lastActionSummary = "Undo"
    }

    func ctaLabel(for group: PhotoGroup? = nil) -> String {
        let group = group ?? currentGroup
        guard let group else { return "Keep Best" }
        let trashCount = selectedTrashPhotoIDs.count
        if trashCount > 0 {
            return "Move \(trashCount) to Trash"
        }
        if group.groupConfidence == .high {
            return "Keep Best"
        }
        return "Review Manually"
    }

    private func updateCurrentOverride() {
        guard let currentFocusedPhoto else { return }
        selectedOverridePhotoID = currentFocusedPhoto.photoId
    }

    private var currentKeeperAssetID: String? {
        currentGroup?.keeperAssetID
    }

    private var currentSelectedKeeperAssetID: String? {
        selectedOverridePhotoID ?? currentKeeperAssetID
    }

    private func isCurrentAsset(_ photoID: String) -> Bool {
        currentGroup?.candidates.contains(where: { $0.photoId == photoID }) == true
    }

    private func isDeleteCandidate(_ photoID: String) -> Bool {
        guard let group = currentGroup else { return false }
        guard let keeper = currentKeeperAssetID else { return false }
        if photoID == keeper {
            return false
        }
        if group.deleteCandidateIDs.isEmpty { return isCurrentAsset(photoID) }
        return group.deleteCandidateIDs.contains(photoID)
    }

    private func advanceGroup() {
        guard currentGroupIndex + 1 < groups.count else {
            selectedTrashPhotoIDs.removeAll()
            return
        }
        currentGroupIndex += 1
        currentPhotoIndex = 0
        selectedTrashPhotoIDs.removeAll()
        protectedPhotoIDs.removeAll()
        selectedOverridePhotoID = currentGroup?.keeperAssetID ?? currentGroup?.candidates.first?.photoId
        if let currentGroup {
            reviewStateByGroupID[currentGroup.id] = reviewStateByGroupID[currentGroup.id] ?? .unreviewed
        }
    }

    private func advanceAfterDuckingCurrentPhoto() {
        guard let group = currentGroup else { return }
        guard let nextIndex = nextReviewablePhotoIndex(after: currentPhotoIndex, in: group) else { return }
        setFocusedPhoto(index: nextIndex)
    }

    private func nextReviewablePhotoIndex(after index: Int, in group: PhotoGroup) -> Int? {
        guard index + 1 < group.candidates.count else { return nil }
        for candidateIndex in (index + 1)..<group.candidates.count {
            let candidate = group.candidates[candidateIndex]
            guard !selectedTrashPhotoIDs.contains(candidate.photoId) else { continue }
            return candidateIndex
        }
        return nil
    }

    private func previousReviewablePhotoIndex(before index: Int, in group: PhotoGroup) -> Int? {
        guard index > 0 else { return nil }
        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            let candidate = group.candidates[candidateIndex]
            guard !selectedTrashPhotoIDs.contains(candidate.photoId) else { continue }
            return candidateIndex
        }
        return nil
    }
}
