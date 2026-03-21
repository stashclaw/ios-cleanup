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

    static func duckDisplay(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .largeTitle) -> Font {
        BrandFont.makeDisplay(size: size, relativeTo: textStyle)
    }

    static func duckBody(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        BrandFont.makeBody(size: size, weight: weight, relativeTo: textStyle)
    }
}

private enum BrandFont {
    static func makeDisplay(size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
        if UIFont(name: "FredokaOne-Regular", size: size) != nil {
            return .custom("FredokaOne-Regular", size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    static func makeBody(size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        let name: String
        switch weight {
        case .bold:
            name = "Nunito-Bold"
        case .semibold:
            name = "Nunito-SemiBold"
        case .medium:
            name = "Nunito-SemiBold"
        default:
            name = "Nunito-Regular"
        }

        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }
}
