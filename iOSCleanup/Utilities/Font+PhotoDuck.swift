import SwiftUI

// NSCache is thread-safe per Apple documentation but is not annotated as Sendable.
// This retroactive conformance silences Swift 6 concurrency warnings project-wide.
extension NSCache: @unchecked @retroactive Sendable {}

extension Font {
    static let duckDisplay  = Font.custom("FredokaOne-Regular", size: 32)
    static let duckTitle    = Font.custom("FredokaOne-Regular", size: 22)
    static let duckHeading  = Font.custom("FredokaOne-Regular", size: 18)
    static let duckButton   = Font.custom("FredokaOne-Regular", size: 16)
    static let duckBody     = Font.custom("Nunito-SemiBold", size: 15)
    static let duckCaption  = Font.custom("Nunito-Regular", size: 13)
    static let duckLabel    = Font.custom("Nunito-Bold", size: 11)
}
