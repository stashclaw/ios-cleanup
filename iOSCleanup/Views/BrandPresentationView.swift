// BrandPresentationView.swift
// Expected PhotoDuck assets: photoduck_logo, photoduck_wordmark, photoduck_icon, photoduck_mascot,
// photoduck_home_mock, photoduck_scan_mock, photoduck_complete_mock.
//
// To use Fredoka One and Nunito, add the font files to the app target and list each filename in
// Info.plist under UIAppFonts. Keep the font names in the helpers below aligned with the files.
//
// If an asset or font is missing, this file already falls back to branded SwiftUI illustrations and
// rounded system fonts. No UIKit views are used.

import SwiftUI
import UIKit

struct BrandPresentationView: View {
    private let palette: [BrandPaletteItem] = [
        .init(name: "Primary Pink", hex: "#F85FA3", color: .photoduckPrimaryPink),
        .init(name: "Soft Pink", hex: "#F9B6D2", color: .photoduckSoftPink),
        .init(name: "Blush Background", hex: "#FFF2F8", color: .photoduckBlushBackground),
        .init(name: "Duck Yellow", hex: "#FFD85A", color: .photoduckDuckYellow),
        .init(name: "Beak Orange", hex: "#F79A2E", color: .photoduckBeakOrange),
        .init(name: "Cream", hex: "#FFF8FB", color: .photoduckCream),
        .init(name: "Rose Text", hex: "#C94C84", color: .photoduckRoseText),
        .init(name: "Deep Berry", hex: "#9D3C66", color: .photoduckDeepBerry)
    ]

    var body: some View {
        GeometryReader { proxy in
            let isCompactWidth = proxy.size.width < 390

            ScrollView {
                VStack(spacing: isCompactWidth ? 18 : 22) {
                    heroSection(isCompactWidth: isCompactWidth)
                    sectionShell(title: "Color Palette", subtitle: "Core brand colors and supportive neutrals") {
                        paletteGrid(isCompactWidth: isCompactWidth)
                    }
                    sectionShell(title: "Typography Scale", subtitle: "Custom font fallbacks keep the system polished on every install") {
                        typographyStack(isCompactWidth: isCompactWidth)
                    }
                    sectionShell(title: "Component Showcase", subtitle: "Buttons, badges, progress, and a sample card") {
                        componentShowcase(isCompactWidth: isCompactWidth)
                    }
                    sectionShell(title: "Mini Product Mockups", subtitle: "Three tiny phone scenes using supplied assets when available") {
                        miniMockups(isCompactWidth: isCompactWidth)
                    }
                    closingBrandMoment
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(Color.photoduckBlushBackground.ignoresSafeArea())
        }
    }

    private func heroSection(isCompactWidth: Bool) -> some View {
        BrandCardContainer {
            ZStack(alignment: .topTrailing) {
                heroBackgroundGlow

                VStack(spacing: isCompactWidth ? 14 : 18) {
                    lockupVisual

                    VStack(spacing: 8) {
                        BrandWordmark()

                        Text("Keep the best. Duck the rest.")
                            .font(.photoduckBody(17, weight: .semibold))
                            .foregroundStyle(Color.photoduckRoseText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    MascotAccentBadge()
                        .padding(.top, isCompactWidth ? 0 : 4)
                }
                .padding(isCompactWidth ? 20 : 24)
            }
        }
    }

    private var heroBackgroundGlow: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .photoduckSoftPink.opacity(0.55),
                            .photoduckSoftPink.opacity(0.05),
                            .clear
                        ],
                        center: .center,
                        startRadius: 12,
                        endRadius: 170
                    )
                )
                .frame(width: 280, height: 280)
                .offset(x: -90, y: -70)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .photoduckDuckYellow.opacity(0.40),
                            .clear
                        ],
                        center: .center,
                        startRadius: 12,
                        endRadius: 125
                    )
                )
                .frame(width: 220, height: 220)
                .offset(x: 82, y: 74)
        }
        .allowsHitTesting(false)
    }

    private var lockupVisual: some View {
        VStack(spacing: 14) {
            BrandAssetImage(
                assetNames: ["photoduck_logo", "photoduck_icon"],
                contentMode: .fit
            ) {
                BrandLogoFallback()
            }
            .frame(width: 126, height: 126)
            .shadow(color: .photoduckPrimaryPink.opacity(0.25), radius: 14, x: 0, y: 10)

            HStack(spacing: 10) {
                BrandAssetImage(
                    assetNames: ["photoduck_mascot"],
                    contentMode: .fit
                ) {
                    SmallMascotSticker()
                }
                .frame(width: 70, height: 70)

                Text("premium-cute cleanup for your camera roll")
                    .font(.photoduckBody(13, weight: .medium))
                    .foregroundStyle(Color.photoduckRoseText.opacity(0.86))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.photoduckCream.opacity(0.76))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.photoduckSoftPink.opacity(0.35), lineWidth: 1)
                    )
            )
        }
    }

    private func paletteGrid(isCompactWidth: Bool) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: isCompactWidth ? 126 : 138), spacing: 12)],
            spacing: 12
        ) {
            ForEach(Array(palette.enumerated()), id: \.offset) { item in
                BrandPaletteSwatch(
                    name: item.element.name,
                    hex: item.element.hex,
                    color: item.element.color
                )
            }
        }
    }

    @ViewBuilder
    private func typographyStack(isCompactWidth: Bool) -> some View {
        if isCompactWidth {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                TypographyRow(
                    label: "Display",
                    sample: "Keep the best.",
                    font: .photoduckDisplay(30),
                    note: "Fredoka One"
                )
                TypographyRow(
                    label: "Title",
                    sample: "Duck the rest.",
                    font: .photoduckDisplay(22),
                    note: "Section headers"
                )
                TypographyRow(
                    label: "Body",
                    sample: "A friendly, polished system for duplicate cleanup and satisfying progress.",
                    font: .photoduckBody(15),
                    note: "Nunito"
                )
                TypographyRow(
                    label: "Caption",
                    sample: "Small helper text and supporting details.",
                    font: .photoduckBody(12, weight: .medium),
                    note: "Labels + hints"
                )
                TypographyRow(
                    label: "Label",
                    sample: "SCAN COMPLETE",
                    font: .photoduckBody(11, weight: .bold),
                    note: "Accent labels"
                )
            }
        } else {
            VStack(spacing: 12) {
                TypographyRow(
                    label: "Display",
                    sample: "Keep the best.",
                    font: .photoduckDisplay(34),
                    note: "Fredoka One + rounded fallback"
                )
                TypographyRow(
                    label: "Title",
                    sample: "Duck the rest.",
                    font: .photoduckDisplay(24),
                    note: "Great for section headers"
                )
                TypographyRow(
                    label: "Body",
                    sample: "A friendly, polished system for duplicate cleanup and satisfying progress.",
                    font: .photoduckBody(16),
                    note: "Nunito + rounded fallback"
                )
                TypographyRow(
                    label: "Caption",
                    sample: "Small helper text and supporting details.",
                    font: .photoduckBody(13, weight: .medium),
                    note: "Used for labels and hints"
                )
                TypographyRow(
                    label: "Label",
                    sample: "SCAN COMPLETE",
                    font: .photoduckBody(12, weight: .bold),
                    note: "All-caps accent labels"
                )
            }
        }
    }

    private func componentShowcase(isCompactWidth: Bool) -> some View {
        VStack(spacing: 14) {
            if isCompactWidth {
                VStack(spacing: 12) {
                    BrandPrimaryButtonSample(title: "Get Started")
                    BrandSecondaryButtonSample(title: "Learn More")
                }
            } else {
                HStack(spacing: 12) {
                    BrandPrimaryButtonSample(title: "Get Started")
                    BrandSecondaryButtonSample(title: "Learn More")
                }
            }

            if isCompactWidth {
                VStack(spacing: 10) {
                    BrandBadge(title: "New", background: .photoduckPrimaryPink, foreground: .white)
                    BrandBadge(title: "Premium", background: .photoduckDuckYellow, foreground: .photoduckDeepBerry)
                    BrandStatPill(
                        title: "244 photos",
                        subtitle: "found",
                        icon: "photo.stack",
                        tint: .photoduckRoseText
                    )
                }
            } else {
                HStack(spacing: 10) {
                    BrandBadge(title: "New", background: .photoduckPrimaryPink, foreground: .white)
                    BrandBadge(title: "Premium", background: .photoduckDuckYellow, foreground: .photoduckDeepBerry)
                    BrandStatPill(
                        title: "244 photos",
                        subtitle: "found",
                        icon: "photo.stack",
                        tint: .photoduckRoseText
                    )
                }
            }

            BrandProgressSample(progress: 0.72)

            BrandRoundedCardExample()
        }
    }

    @ViewBuilder
    private func miniMockups(isCompactWidth: Bool) -> some View {
        if isCompactWidth {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    mockupCards
                }
                .padding(.vertical, 2)
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                spacing: 12
            ) {
                mockupCards
            }
        }
    }

    @ViewBuilder
    private var mockupCards: some View {
        MiniPhoneMockup(
            title: "Home",
            subtitle: "Overview and scan entry",
            assetNames: ["photoduck_home_mock"],
            kind: .home
        )

        MiniPhoneMockup(
            title: "Scan",
            subtitle: "Progress in motion",
            assetNames: ["photoduck_scan_mock"],
            kind: .scan
        )

        MiniPhoneMockup(
            title: "Completion",
            subtitle: "Results and celebration",
            assetNames: ["photoduck_complete_mock"],
            kind: .completion
        )
    }

    private var closingBrandMoment: some View {
        BrandCardContainer(padding: 20) {
            HStack(alignment: .center, spacing: 16) {
                BrandAssetImage(
                    assetNames: ["photoduck_mascot"],
                    contentMode: .fit
                ) {
                    SmallMascotSticker()
                }
                .frame(width: 88, height: 88)
                .shadow(color: .photoduckPrimaryPink.opacity(0.18), radius: 12, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Clean up your camera roll with a little help from PhotoDuck.")
                        .font(.photoduckBody(17, weight: .semibold))
                        .foregroundStyle(Color.photoduckDeepBerry)

                    Text("Friendly, bright, and satisfying by design.")
                        .font(.photoduckBody(13, weight: .medium))
                        .foregroundStyle(Color.photoduckRoseText.opacity(0.85))
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func sectionShell<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        BrandCardContainer {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.photoduckDisplay(22))
                        .foregroundStyle(Color.photoduckDeepBerry)

                    Text(subtitle)
                        .font(.photoduckBody(13, weight: .medium))
                        .foregroundStyle(Color.photoduckRoseText.opacity(0.85))
                }

                content()
            }
            .padding(20)
        }
    }
}

// MARK: - Reusable Card Shell

private struct BrandCardContainer<Content: View>: View {
    var padding: CGFloat = 18
    let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.photoduckCream.opacity(0.98),
                                Color.white.opacity(0.96)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.photoduckSoftPink.opacity(0.35), lineWidth: 1)
                    )
            )
            .shadow(color: .photoduckPrimaryPink.opacity(0.12), radius: 18, x: 0, y: 10)
    }
}

// MARK: - Palette Swatch

private struct BrandPaletteSwatch: View {
    let name: String
    let hex: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(color)
                .frame(height: 76)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 20, height: 20)
                        .padding(10)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.photoduckBody(14, weight: .semibold))
                    .foregroundStyle(Color.photoduckDeepBerry)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Text(hex)
                    .font(.photoduckBody(12, weight: .medium))
                    .foregroundStyle(Color.photoduckRoseText.opacity(0.78))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.52))
        )
        .shadow(color: .photoduckPrimaryPink.opacity(0.08), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Typography Row

private struct TypographyRow: View {
    let label: String
    let sample: String
    let font: Font
    let note: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label.uppercased())
                .font(.photoduckBody(11, weight: .bold))
                .foregroundStyle(Color.photoduckRoseText)
                .frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(sample)
                    .font(font)
                    .foregroundStyle(Color.photoduckDeepBerry)
                    .fixedSize(horizontal: false, vertical: true)

                Text(note)
                    .font(.photoduckBody(12, weight: .medium))
                    .foregroundStyle(Color.photoduckRoseText.opacity(0.8))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.54))
        )
    }
}

// MARK: - Component Samples

private struct BrandPrimaryButtonSample: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.photoduckBody(15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [.photoduckPrimaryPink, .photoduckRoseText],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule(style: .continuous))
            .shadow(color: .photoduckPrimaryPink.opacity(0.25), radius: 10, x: 0, y: 8)
    }
}

private struct BrandSecondaryButtonSample: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.photoduckBody(15, weight: .bold))
            .foregroundStyle(Color.photoduckRoseText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.photoduckCream)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.photoduckPrimaryPink.opacity(0.55), lineWidth: 1.4)
            )
            .clipShape(Capsule(style: .continuous))
    }
}

private struct BrandBadge: View {
    let title: String
    let background: Color
    let foreground: Color

    var body: some View {
        Text(title)
            .font(.photoduckBody(12, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background)
            .clipShape(Capsule(style: .continuous))
    }
}

private struct BrandProgressSample: View {
    let progress: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Progress")
                    .font(.photoduckBody(13, weight: .semibold))
                    .foregroundStyle(Color.photoduckDeepBerry)

                Spacer()

                Text("\(Int(progress * 100))%")
                    .font(.photoduckBody(13, weight: .bold))
                    .foregroundStyle(Color.photoduckRoseText)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.photoduckSoftPink.opacity(0.35))

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.photoduckDuckYellow, .photoduckPrimaryPink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width * progress)
                }
            }
            .frame(height: 14)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.56))
        )
    }
}

private struct BrandStatPill: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.photoduckBody(13, weight: .bold))
                    .foregroundStyle(Color.photoduckDeepBerry)

                Text(subtitle)
                    .font(.photoduckBody(11, weight: .medium))
                    .foregroundStyle(Color.photoduckRoseText.opacity(0.78))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.62))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.photoduckSoftPink.opacity(0.48), lineWidth: 1)
        )
        .clipShape(Capsule(style: .continuous))
    }
}

private struct BrandRoundedCardExample: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.photoduckPrimaryPink.opacity(0.95), .photoduckBeakOrange.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                )
                .shadow(color: .photoduckPrimaryPink.opacity(0.25), radius: 10, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("Duplicate photos")
                    .font(.photoduckBody(15, weight: .bold))
                    .foregroundStyle(Color.photoduckDeepBerry)

                Text("Keep the best shot and duck the rest.")
                    .font(.photoduckBody(13, weight: .medium))
                    .foregroundStyle(Color.photoduckRoseText.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.photoduckCream.opacity(0.9))
        )
    }
}

// MARK: - Mini Phone Mockups

private struct MiniPhoneMockup: View {
    enum Kind {
        case home
        case scan
        case completion
    }

    let title: String
    let subtitle: String
    let assetNames: [String]
    let kind: Kind

    var body: some View {
        BrandCardContainer(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.photoduckDisplay(18))
                        .foregroundStyle(Color.photoduckDeepBerry)

                    Text(subtitle)
                        .font(.photoduckBody(12, weight: .medium))
                        .foregroundStyle(Color.photoduckRoseText.opacity(0.8))
                }

                PhoneFrame {
                    BrandAssetImage(assetNames: assetNames, contentMode: .fit) {
                        MiniMockupFallback(kind: kind)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                .frame(height: 282)
            }
            .padding(14)
        }
    }
}

private struct PhoneFrame<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.10, blue: 0.16),
                            Color(red: 0.28, green: 0.15, blue: 0.24)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .padding(4)

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.photoduckBlushBackground)
                .padding(10)

            VStack(spacing: 0) {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .frame(width: 70, height: 6)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                content
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .shadow(color: .photoduckPrimaryPink.opacity(0.16), radius: 16, x: 0, y: 10)
    }
}

private struct MiniMockupFallback: View {
    let kind: MiniPhoneMockup.Kind

    var body: some View {
        switch kind {
        case .home:
            MiniHomeFallback()
        case .scan:
            MiniScanFallback()
        case .completion:
            MiniCompletionFallback()
        }
    }
}

private struct MiniHomeFallback: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.photoduckCream,
                    Color.photoduckBlushBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PhotoDuck")
                            .font(.photoduckBody(14, weight: .bold))
                            .foregroundStyle(Color.photoduckDeepBerry)
                        Text("Home")
                            .font(.photoduckBody(10, weight: .medium))
                            .foregroundStyle(Color.photoduckRoseText)
                    }

                    Spacer()

                    SmallMascotSticker(size: 34)
                }

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.photoduckPrimaryPink, .photoduckRoseText],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 82)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.white.opacity(0.22))
                                .frame(width: 46, height: 46)
                                .overlay(Image(systemName: "photo.stack.fill").foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("2,344 photos")
                                    .font(.photoduckBody(14, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("57 duplicates ready")
                                    .font(.photoduckBody(11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                            Spacer()
                        }
                        .padding(14)
                    }

                VStack(spacing: 10) {
                    ForEach(0..<2, id: \.self) { index in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(index == 0 ? Color.photoduckDuckYellow : Color.photoduckSoftPink)
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Image(systemName: index == 0 ? "sparkles" : "photo.on.rectangle")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Color.photoduckDeepBerry)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(index == 0 ? "Similar shots" : "Best picks")
                                    .font(.photoduckBody(12, weight: .bold))
                                    .foregroundStyle(Color.photoduckDeepBerry)
                                Text(index == 0 ? "6 groups found" : "Keep the sharpest one")
                                    .font(.photoduckBody(10, weight: .medium))
                                    .foregroundStyle(Color.photoduckRoseText)
                            }

                            Spacer()
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.78))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }
}

private struct MiniScanFallback: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.photoduckCream,
                    Color.white
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 16) {
                HStack {
                    Text("Scanning")
                        .font(.photoduckBody(14, weight: .bold))
                        .foregroundStyle(Color.photoduckDeepBerry)
                    Spacer()
                    BrandBadge(title: "72%", background: .photoduckDuckYellow, foreground: .photoduckDeepBerry)
                }

                ZStack {
                    Circle()
                        .stroke(Color.photoduckSoftPink.opacity(0.5), lineWidth: 14)
                        .frame(width: 124, height: 124)

                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(
                            LinearGradient(
                                colors: [.photoduckPrimaryPink, .photoduckBeakOrange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 124, height: 124)
                        .rotationEffect(.degrees(-90))

                    SmallMascotSticker(size: 54)
                }

                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white)
                        .frame(height: 44)
                        .overlay(
                            HStack {
                                Circle()
                                    .fill(Color.photoduckSoftPink)
                                    .frame(width: 20, height: 20)
                                Text("Finding duplicates...")
                                    .font(.photoduckBody(12, weight: .semibold))
                                    .foregroundStyle(Color.photoduckDeepBerry)
                                Spacer()
                            }
                                .padding(.horizontal, 12)
                        )

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.photoduckPrimaryPink.opacity(0.12))
                        .frame(height: 44)
                        .overlay(
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Color.photoduckRoseText)
                                Text("Duck the rest")
                                    .font(.photoduckBody(12, weight: .bold))
                                    .foregroundStyle(Color.photoduckRoseText)
                                Spacer()
                            }
                                .padding(.horizontal, 12)
                        )
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }
}

private struct MiniCompletionFallback: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.photoduckBlushBackground,
                    Color.photoduckCream
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nice Work")
                            .font(.photoduckBody(14, weight: .bold))
                            .foregroundStyle(Color.photoduckDeepBerry)
                        Text("2.3 GB freed")
                            .font(.photoduckBody(11, weight: .medium))
                            .foregroundStyle(Color.photoduckRoseText)
                    }

                    Spacer()

                    BrandBadge(title: "Complete", background: .photoduckPrimaryPink, foreground: .white)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.photoduckPrimaryPink, .photoduckRoseText],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 152)
                        .overlay(
                            VStack(spacing: 10) {
                                SmallMascotSticker(size: 60)
                                Text("Cleaned up")
                                    .font(.photoduckBody(14, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("244 items reviewed")
                                    .font(.photoduckBody(11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                        )

                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.5), lineWidth: 2)
                        .frame(height: 152)
                }

                HStack(spacing: 10) {
                    BrandBadge(title: "Share", background: .photoduckDuckYellow, foreground: .photoduckDeepBerry)
                    BrandBadge(title: "Done", background: .photoduckPrimaryPink, foreground: .white)
                    Spacer()
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }
}

// MARK: - Brand Asset Image

private struct BrandAssetImage<Fallback: View>: View {
    let assetNames: [String]
    let contentMode: ContentMode
    let fallback: Fallback

    init(assetNames: [String], contentMode: ContentMode, @ViewBuilder fallback: () -> Fallback) {
        self.assetNames = assetNames
        self.contentMode = contentMode
        self.fallback = fallback()
    }

    var body: some View {
        if let assetName = assetNames.first(where: { UIImage(named: $0) != nil }) {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            fallback
        }
    }
}

// MARK: - Fallback Logo / Mascot

private struct BrandLogoFallback: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.photoduckPrimaryPink, .photoduckRoseText],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.75), lineWidth: 2)
                .padding(5)

            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 82, height: 82)
                    .offset(x: -10, y: -10)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 80, height: 80)
                    .overlay(
                        ZStack(alignment: .bottomLeading) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.photoduckPrimaryPink, .photoduckSoftPink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 80, height: 80)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "sparkle")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(11)
                                }

                            Circle()
                                .fill(Color.photoduckDuckYellow)
                                .frame(width: 52, height: 52)
                                .offset(x: -8, y: 10)

                            Ellipse()
                                .fill(Color.photoduckBeakOrange)
                                .frame(width: 32, height: 20)
                                .offset(x: 22, y: 18)

                            Circle()
                                .fill(Color.black.opacity(0.85))
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: 2)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.9), lineWidth: 4)
                    )
            }
            .frame(width: 88, height: 88)
        }
    }
}

private struct SmallMascotSticker: View {
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.photoduckDuckYellow.opacity(0.95),
                            Color.photoduckDuckYellow.opacity(0.75),
                            Color.photoduckPrimaryPink.opacity(0.18)
                        ],
                        center: .topLeading,
                        startRadius: 4,
                        endRadius: size * 0.75
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: .photoduckDuckYellow.opacity(0.35), radius: 10, x: 0, y: 6)

            Circle()
                .fill(Color.black.opacity(0.82))
                .frame(width: size * 0.14, height: size * 0.14)
                .offset(x: -size * 0.16, y: -size * 0.12)

            Circle()
                .fill(Color.black.opacity(0.82))
                .frame(width: size * 0.14, height: size * 0.14)
                .offset(x: size * 0.08, y: -size * 0.10)

            Capsule(style: .continuous)
                .fill(Color.photoduckBeakOrange)
                .frame(width: size * 0.34, height: size * 0.20)
                .offset(x: size * 0.10, y: size * 0.10)

            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: size * 0.18, height: size * 0.18)
                .offset(x: size * 0.18, y: -size * 0.12)
        }
        .accessibilityHidden(true)
    }
}

private struct MascotAccentBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            SmallMascotSticker(size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Brand mood")
                    .font(.photoduckBody(11, weight: .bold))
                    .foregroundStyle(Color.photoduckRoseText)
                Text("Light, satisfying, premium-cute")
                    .font(.photoduckBody(12, weight: .medium))
                    .foregroundStyle(Color.photoduckDeepBerry)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.photoduckSoftPink.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Wordmark

private struct BrandWordmark: View {
    var body: some View {
        BrandAssetImage(assetNames: ["photoduck_wordmark"], contentMode: .fit) {
            Text("PhotoDuck")
                .font(.photoduckDisplay(30))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.photoduckPrimaryPink, .photoduckDeepBerry],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .minimumScaleFactor(0.85)
                .lineLimit(1)
        }
        .frame(height: 44)
        .accessibilityLabel("PhotoDuck")
    }
}

// MARK: - Typography Helpers

private enum BrandFontResolver {
    static func display(_ size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
        if let name = preferredFontName(candidates: [
            "FredokaOne-Regular",
            "Fredoka One",
            "FredokaOne",
            "FredokaOne-Regular.ttf"
        ]) {
            return .custom(name, size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    static func body(_ size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        let candidates: [String]
        switch weight {
        case .bold:
            candidates = ["Nunito-Bold", "Nunito Bold", "Nunito"]
        case .semibold:
            candidates = ["Nunito-SemiBold", "Nunito-Semibold", "Nunito"]
        case .medium:
            candidates = ["Nunito-Medium", "Nunito"]
        default:
            candidates = ["Nunito-Regular", "Nunito"]
        }

        if let name = preferredFontName(candidates: candidates) {
            return .custom(name, size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }

    private static func preferredFontName(candidates: [String]) -> String? {
        for candidate in candidates {
            if UIFont(name: candidate, size: 12) != nil {
                return candidate
            }
        }
        return nil
    }
}

private extension Font {
    static func photoduckDisplay(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .largeTitle) -> Font {
        BrandFontResolver.display(size, relativeTo: textStyle)
    }

    static func photoduckBody(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        BrandFontResolver.body(size, weight: weight, relativeTo: textStyle)
    }
}

// MARK: - Colors

private struct BrandPaletteItem {
    let name: String
    let hex: String
    let color: Color
}

#Preview {
    BrandPresentationView()
}
