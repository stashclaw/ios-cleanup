import SwiftUI

extension Color {
    static let photoduckPrimaryPink = Color(hex: "#F85FA3")
    static let photoduckSoftPink = Color(hex: "#F9B6D2")
    static let photoduckBlushBackground = Color(hex: "#FFF2F8")
    static let photoduckDuckYellow = Color(hex: "#FFD85A")
    static let photoduckBeakOrange = Color(hex: "#F79A2E")
    static let photoduckCream = Color(hex: "#FFF8FB")
    static let photoduckRoseText = Color(hex: "#C94C84")
    static let photoduckDeepBerry = Color(hex: "#9D3C66")
}

private extension Color {
    init(hex: String, opacity: Double = 1.0) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)

        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        default:
            r = 1
            g = 1
            b = 1
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
