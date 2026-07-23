import SwiftUI
import UIKit

// MARK: - Brand Assets

struct PhotoDuckAssetImage<Fallback: View>: View {
    let assetNames: [String]
    let fallback: Fallback

    init(assetNames: [String], @ViewBuilder fallback: () -> Fallback) {
        self.assetNames = assetNames
        self.fallback = fallback()
    }

    var body: some View {
        if let assetName = assetNames.first(where: { UIImage(named: $0) != nil }) {
            Image(assetName)
                .resizable()
                .scaledToFit()
        } else {
            fallback
        }
    }
}

struct PhotoDuckIconMark: View {
    var size: CGFloat = 36

    var body: some View {
        PhotoDuckAssetImage(assetNames: ["photoduck_icon"]) {
            PhotoDuckMascotFallback(size: size)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct PhotoDuckBrandLockup: View {
    var iconSize: CGFloat = 32
    var wordmarkHeight: CGFloat = 24
    var showsIcon = true

    var body: some View {
        HStack(spacing: max(8, iconSize * 0.22)) {
            if showsIcon {
                PhotoDuckIconMark(size: iconSize)
            }

            PhotoDuckAssetImage(assetNames: ["photoduck_wordmark"]) {
                Text("PhotoDuck")
                    .font(.duckDisplay(wordmarkHeight * 0.78))
                    .foregroundStyle(Color.duckPink)
            }
            .frame(width: wordmarkHeight * 3.15, height: wordmarkHeight)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PhotoDuck")
    }
}

struct PhotoDuckMascotArt: View {
    var size: CGFloat

    var body: some View {
        PhotoDuckAssetImage(assetNames: ["photoduck_mascot"]) {
            PhotoDuckMascotFallback(size: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PhotoDuckMascotFallback: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.duckYellow, Color.duckPink.opacity(0.85)],
                        center: .topLeading,
                        startRadius: 4,
                        endRadius: size * 0.8
                    )
                )
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: size * 0.14, height: size * 0.14)
                .offset(x: -size * 0.16, y: -size * 0.10)
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: size * 0.14, height: size * 0.14)
                .offset(x: size * 0.08, y: -size * 0.10)
            Capsule(style: .continuous)
                .fill(Color.duckOrange)
                .frame(width: size * 0.34, height: size * 0.20)
                .offset(x: size * 0.12, y: size * 0.10)
        }
        .frame(width: size, height: size)
    }
}

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
                        colors: [Color.duckPink, Color.duckRose],
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
                .font(.duckCaption.weight(.semibold))
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

// MARK: - BestShotBadge

struct BestShotBadge: View {
    let isRecommended: Bool
    let needsReview: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isRecommended ? "star.fill" : "exclamationmark.triangle.fill")
                .font(.duckMicro.weight(.bold))
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
