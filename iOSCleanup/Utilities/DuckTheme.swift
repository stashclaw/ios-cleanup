import SwiftUI

// Semantic design tokens for the PhotoDuck polish pass. Each color maps to a
// colorset in Assets.xcassets/Colors; the generated `duck*` symbols remain
// available as the deprecated brand-name layer for one release.
extension Color {
    static let backgroundBlush = Color.duckBlush        // screen backgrounds
    static let surface = Color.duckCream                // cards
    static let surfaceElevated = Color.duckSurfaceElevated
    static let textPrimary = Color.duckBerry
    static let textSecondary = Color.duckRose
    static let accentPrimary = Color.duckPink
    static let accentDeep = Color.duckAccentDeep        // gradient end / pressed
    static let success = Color.duckSuccess
    static let danger = Color.duckDanger
    static let warning = Color.duckWarning
    static let mascotYellow = Color.duckYellow          // decorative only
    static let decorPink = Color.duckSoftPink           // fills/strokes only, never text
    static let berryBlack = Color.duckBerryBlack        // brand dark background
}

enum DuckRadius {
    static let s: CGFloat = 10   // chips, thumbs
    static let m: CGFloat = 16   // buttons, tiles
    static let l: CGFloat = 24   // cards, sheets
}

enum DuckSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let ml: CGFloat = 20
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

// The primary gradient CTA fill. The colored glow
// (`.duckPrimaryGlow()`) is reserved for this fill only.
extension LinearGradient {
    static let duckPrimaryCTA = LinearGradient(
        colors: [Color.accentPrimary, Color.accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension View {
    /// Colored glow reserved for the primary gradient CTA (CSS: 0 4 12 Accent @ 35%).
    func duckPrimaryGlow() -> some View {
        shadow(color: Color.accentPrimary.opacity(0.35), radius: 6, x: 0, y: 4)
    }

    /// Standard card elevation: hairline stroke + tight shadow. No floaty drop shadows.
    func duckCardElevation(cornerRadius: CGFloat = DuckRadius.l) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.textSecondary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.textPrimary.opacity(0.06), radius: 1, x: 0, y: 1)
    }
}
