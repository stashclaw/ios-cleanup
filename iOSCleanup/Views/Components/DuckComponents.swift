import Photos
import SwiftUI

// MARK: - DuckCard

struct DuckCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(Color.duckCream, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: Color.duckPink.opacity(0.08), radius: 8, x: 0, y: 3)
    }
}

// MARK: - DuckPrimaryButton

struct DuckPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.duckButton)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    LinearGradient(
                        colors: [Color.duckPink, Color(red: 0.831, green: 0.271, blue: 0.541)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 50)
                )
                .shadow(color: Color.duckPink.opacity(0.35), radius: 12, x: 0, y: 4)
        }
    }
}

// MARK: - DuckOutlineButton

struct DuckOutlineButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.duckButton)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 50))
                .overlay(
                    RoundedRectangle(cornerRadius: 50)
                        .strokeBorder(color, lineWidth: 1.5)
                )
        }
    }
}

// MARK: - DuckBadge

struct DuckBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.duckLabel)
            .foregroundStyle(Color.white)
            .frame(width: 22, height: 22)
            .background(color, in: Circle())
    }
}

// MARK: - DuckSectionHeader

struct DuckSectionHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.duckHeading)
                .foregroundStyle(Color.duckBerry)
            Rectangle()
                .fill(Color.duckSoftPink)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - DuckProgressBar

struct DuckProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.duckSoftPink)
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: geo.size.width * min(max(progress, 0), 1), height: 6)
                    .animation(.linear(duration: 0.3), value: progress)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - PrimaryMetricCard

struct PrimaryMetricCard<Accessory: View>: View {
    let title: String
    let value: String
    let detail: String
    let accent: Color
    let progress: Double?
    let accessory: Accessory

    init(
        title: String,
        value: String,
        detail: String,
        accent: Color,
        progress: Double? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.accent = accent
        self.progress = progress
        self.accessory = accessory()
    }

    var body: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)

                        Text(value)
                            .font(.duckDisplay)
                            .foregroundStyle(accent)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)

                        Text(detail)
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckBerry)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    accessory
                }

                if let progress {
                    DuckProgressBar(progress: progress, color: accent)
                }
            }
            .padding(18)
        }
    }
}

// MARK: - StatPill

struct StatPill: View {
    let title: String
    let value: String
    let accent: Color
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(accent.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.duckLabel)
                    .foregroundStyle(Color.duckRose)
                Text(value)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.duckBerry)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.duckCream, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        )
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let title: String
    let accent: Color

    var body: some View {
        Text(title)
            .font(.duckLabel)
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(accent.opacity(0.14), in: Capsule(style: .continuous))
    }
}

// MARK: - ReviewDecisionHUD

struct ReviewDecisionHUD: View {
    let groupPosition: String
    let photoCount: Int
    let reclaimableBytes: Int64
    let confidenceLabel: String
    let contextLabel: String?

    var body: some View {
        DuckCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Group \(groupPosition)")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                    Text("\(photoCount) photos")
                        .font(.duckHeading)
                        .foregroundStyle(Color.duckBerry)
                    if let contextLabel, !contextLabel.isEmpty {
                        Text(contextLabel)
                            .font(.duckLabel)
                            .foregroundStyle(Color.duckRose)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    StatusBadge(
                        title: confidenceLabel,
                        accent: confidenceLabel.lowercased().contains("high") ? .duckPink : .duckOrange
                    )
                    Text(ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file))
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.duckBerry)
                        .monospacedDigit()
                }
            }
            .padding(16)
        }
    }
}

// MARK: - BestShotBadge

struct BestShotBadge: View {
    let isRecommended: Bool
    let needsReview: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isRecommended ? "star.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
            Text(isRecommended ? "Recommended Keeper" : "Needs Review")
        }
        .font(.duckLabel)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(Color.white)
        .background(
            LinearGradient(
                colors: isRecommended
                    ? [Color.duckPink, Color.duckOrange.opacity(0.9)]
                    : [Color.duckOrange, Color.duckRose],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: Capsule()
        )
        .shadow(color: Color.duckPink.opacity(0.18), radius: 8, x: 0, y: 3)
        .accessibilityLabel(isRecommended ? "Recommended Keeper" : "Needs Review")
    }
}

// MARK: - ReasonChipsRow

struct ReasonChipsRow: View {
    let reasons: [String]
    let negativeReasons: [String]

    init(reasons: [String], negativeReasons: [String] = []) {
        self.reasons = reasons
        self.negativeReasons = negativeReasons
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(reasons, id: \.self) { reason in
                    reasonChip(title: reason, positive: true)
                }
                ForEach(negativeReasons, id: \.self) { reason in
                    reasonChip(title: reason, positive: false)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func reasonChip(title: String, positive: Bool) -> some View {
        Text(title)
            .font(.duckLabel)
            .foregroundStyle(positive ? Color.duckRose : Color.duckBerry)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                (positive ? Color.duckSoftPink : Color.duckCream)
                    .opacity(positive ? 0.8 : 1.0),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(positive ? Color.duckPink.opacity(0.12) : Color.duckSoftPink.opacity(0.9), lineWidth: 1)
            )
    }
}

// MARK: - ThumbnailRail

struct ThumbnailRail: View {
    let candidates: [SimilarPhotoCandidate]
    let currentIndex: Int
    let selectedKeeperID: String?
    let onSelect: (Int) -> Void

    @State private var thumbnails: [String: UIImage] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(candidates.enumerated()), id: \.element.photoId) { index, candidate in
                    ThumbnailRailCell(
                        candidate: candidate,
                        image: thumbnails[candidate.photoId],
                        isCurrent: index == currentIndex,
                        isSelectedKeeper: selectedKeeperID == candidate.photoId,
                        onTap: { onSelect(index) }
                    )
                }
            }
            .padding(.horizontal, 2)
        }
        .task(id: candidates.map(\.photoId).joined(separator: ",")) {
            await loadThumbnails()
        }
    }

    private func loadThumbnails() async {
        let missing = candidates.filter { thumbnails[$0.photoId] == nil }
        guard !missing.isEmpty else { return }

        // One batch fetch for all missing asset IDs instead of N separate DB queries.
        let ids = missing.map(\.assetReference)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assetMap: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in assetMap[asset.localIdentifier] = asset }

        // Load all thumbnails in parallel, then assign once to trigger one re-render.
        var loaded: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for candidate in missing {
                guard let asset = assetMap[candidate.assetReference] else { continue }
                let photoId = candidate.photoId
                group.addTask {
                    let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                        let options = PHImageRequestOptions()
                        options.deliveryMode = .fastFormat
                        options.isNetworkAccessAllowed = true
                        PHImageManager.default().requestImage(
                            for: asset,
                            targetSize: CGSize(width: 180, height: 180),
                            contentMode: .aspectFill,
                            options: options
                        ) { result, info in
                            // .fastFormat fires twice (degraded then final).
                            // Without this guard the continuation resumes twice → fatal crash.
                            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                            guard !isDegraded else { return }
                            continuation.resume(returning: result)
                        }
                    }
                    return (photoId, image)
                }
            }
            for await (id, image) in group {
                if let image { loaded[id] = image }
            }
        }
        for (id, image) in loaded { thumbnails[id] = image }
    }
}

private struct ThumbnailRailCell: View {
    let candidate: SimilarPhotoCandidate
    let image: UIImage?
    let isCurrent: Bool
    let isSelectedKeeper: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color.duckSoftPink.opacity(0.55), Color.duckCream],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .overlay(ProgressView().tint(Color.duckPink))
                    }
                }
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if candidate.isBestShot || isSelectedKeeper {
                    BestShotBadge(isRecommended: true, needsReview: false)
                        .padding(6)
                }

                if isSelectedKeeper {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.duckPink)
                                .padding(6)
                                .background(Color.white.opacity(0.95), in: Circle())
                                .shadow(color: Color.duckPink.opacity(0.16), radius: 8, x: 0, y: 3)
                        }
                    }
                    .frame(width: 74, height: 74)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelectedKeeper ? Color.duckPink : (isCurrent ? Color.white.opacity(0.85) : Color.clear),
                        lineWidth: isSelectedKeeper ? 2.5 : 2
                    )
            )
            .shadow(
                color: isSelectedKeeper ? Color.duckPink.opacity(0.24) : Color.duckPink.opacity(isCurrent ? 0.16 : 0.06),
                radius: isSelectedKeeper ? 14 : (isCurrent ? 10 : 6),
                x: 0,
                y: 4
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ActionBar

struct ActionBar: View {
    let keepTitle: String
    let neutralTitle: String
    let destructiveTitle: String
    let destructiveIsPaid: Bool
    let onKeep: () -> Void
    let onNeutral: () -> Void
    let onDestructive: () -> Void
    let onMore: (() -> Void)?

    init(
        keepTitle: String,
        neutralTitle: String,
        destructiveTitle: String,
        destructiveIsPaid: Bool = true,
        onKeep: @escaping () -> Void,
        onNeutral: @escaping () -> Void,
        onDestructive: @escaping () -> Void,
        onMore: (() -> Void)? = nil
    ) {
        self.keepTitle = keepTitle
        self.neutralTitle = neutralTitle
        self.destructiveTitle = destructiveTitle
        self.destructiveIsPaid = destructiveIsPaid
        self.onKeep = onKeep
        self.onNeutral = onNeutral
        self.onDestructive = onDestructive
        self.onMore = onMore
    }

    var body: some View {
        VStack(spacing: 12) {
            DuckPrimaryButton(title: keepTitle, action: onKeep)

            HStack(spacing: 10) {
                DuckOutlineButton(title: neutralTitle, color: .duckRose, action: onNeutral)
                cautiousDestructiveButton
            }

            if let onMore {
                Button(action: onMore) {
                    Text("More")
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.duckRose)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    private var cautiousDestructiveButton: some View {
        Button(action: onDestructive) {
            HStack(spacing: 5) {
                if destructiveIsPaid {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityLabel("Pro feature")
                }
                Text(destructiveTitle)
            }
            .font(.duckButton)
            .foregroundStyle(Color.duckRose)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 50))
            .overlay(
                RoundedRectangle(cornerRadius: 50)
                    .strokeBorder(Color.duckRose.opacity(0.45), lineWidth: 1.2)
            )
        }
    }
}

// MARK: - UndoFeedbackBar

struct UndoFeedbackBar: View {
    let movedCount: Int
    let reclaimedBytes: Int64
    let onUndo: () -> Void
    let onReviewTrash: (() -> Void)?

    private var countLabel: String {
        "\(movedCount) photo\(movedCount == 1 ? "" : "s")"
    }

    private var bytesLabel: String {
        ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file)
    }

    var body: some View {
        DuckCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Moved \(countLabel)")
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.duckBerry)
                    Text("\(bytesLabel) reclaimed")
                        .font(.duckLabel)
                        .foregroundStyle(Color.duckRose)
                }

                Spacer(minLength: 12)

                if let onReviewTrash {
                    Button("Review Trash", action: onReviewTrash)
                        .font(.duckLabel.weight(.semibold))
                        .foregroundStyle(Color.duckPink)
                }

                Button("Undo", action: onUndo)
                    .font(.duckLabel.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.duckPink, in: Capsule())
            }
            .padding(14)
        }
    }
}

// MARK: - BestShotExplanationSheet

struct BestShotExplanationSheet: View {
    let title: String
    let reasons: [String]
    let issueFlags: [IssueFlag]
    let confidenceLabel: String

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.duckSoftPink)
                .frame(width: 38, height: 4)
                .padding(.top, 10)

            VStack(spacing: 8) {
                Text(title)
                    .font(.duckTitle)
                    .foregroundStyle(Color.duckBerry)
                StatusBadge(title: confidenceLabel, accent: confidenceLabel.lowercased().contains("high") ? .duckPink : .duckOrange)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(reasons, id: \.self) { reason in
                    labelRow(title: reason, systemImage: "checkmark.circle.fill", color: .duckPink)
                }

                if !issueFlags.isEmpty {
                    ForEach(issueFlags.prefix(4), id: \.self) { flag in
                        labelRow(title: flag.title, systemImage: flag.systemImage, color: .duckOrange)
                    }
                }
            }
            .padding(.horizontal, 8)

            Text("AI recommends this shot, but you stay in control.")
                .font(.duckCaption)
                .foregroundStyle(Color.duckRose)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.duckCream.ignoresSafeArea())
    }

    private func labelRow(title: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
                .font(.duckBody)
                .foregroundStyle(Color.duckBerry)
            Spacer(minLength: 0)
        }
    }
}
