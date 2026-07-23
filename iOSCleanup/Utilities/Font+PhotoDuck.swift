import SwiftUI
import UIKit

extension Font {
    static let duckDisplay = BrandFont.makeDisplay(size: 32, relativeTo: .largeTitle)
    static let duckTitle = BrandFont.makeDisplay(size: 22, relativeTo: .title)
    static let duckHeading = BrandFont.makeDisplay(size: 18, relativeTo: .headline)
    static let duckButton = BrandFont.makeBody(size: 16, weight: .semibold, relativeTo: .body)
    static let duckBody = BrandFont.makeBody(size: 15, weight: .semibold, relativeTo: .body)
    static let duckCaption = BrandFont.makeBody(size: 13, weight: .regular, relativeTo: .caption)
    static let duckLabel = BrandFont.makeBody(size: 11, weight: .bold, relativeTo: .caption2)
    static let duckStat = BrandFont.makeBody(size: 17, weight: .bold, relativeTo: .body).monospacedDigit()
    static let duckMicro = BrandFont.makeBody(size: 10, weight: .semibold, relativeTo: .caption2)

    static func duckDisplay(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .largeTitle) -> Font {
        BrandFont.makeDisplay(size: size, relativeTo: textStyle)
    }

    static func duckBody(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        BrandFont.makeBody(size: size, weight: weight, relativeTo: textStyle)
    }
}

enum DuckSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
}

enum DuckCornerRadius {
    static let control: CGFloat = 12
    static let card: CGFloat = 16
    static let hero: CGFloat = 30
}

private enum BrandFont {
    static func makeDisplay(size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
        if UIFont(name: "BricolageGrotesque-SemiBold", size: size) != nil {
            return .custom("BricolageGrotesque-SemiBold", size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    static func makeBody(size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        let name: String
        switch weight {
        case .bold:
            name = "Manrope-Bold"
        case .semibold:
            name = "Manrope-SemiBold"
        case .medium:
            name = "Manrope-Medium"
        default:
            name = "Manrope-Regular"
        }

        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }
}
