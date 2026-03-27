import SwiftUI

/// Reason why a photo was flagged as a "wasted shot" beyond low quality score.
enum WastedReason: String, Codable, Hashable, Equatable, Sendable, CaseIterable {
    case darkShot       // Nearly-black photo — luminance < ~8%
    case qrCode         // Contains a QR code / barcode (unlikely to need as a photo)
    case screenPhoto    // Photo of a screen / monitor / TV
    case whiteboard     // Photo of a whiteboard / handwritten note / document
    case memeForwarded  // Forwarded meme or social-media repost with text overlay / watermark
    case eyesClosed     // Face detected with both eyes closed
    case blurryPhoto    // Blurry photo not already in a duplicate group
    case noSubject      // No salient subject detected by Vision saliency
    case lowLight       // Dim but not black — luminance 8–15%
    case sharedPhoto    // Likely received via message / AirDrop (heuristic-based)

    var label: String {
        switch self {
        case .darkShot:      return "Dark Shot"
        case .qrCode:        return "QR Code"
        case .screenPhoto:   return "Screen Photo"
        case .whiteboard:    return "Whiteboard"
        case .memeForwarded: return "Meme / Forwarded"
        case .eyesClosed:    return "Eyes Closed"
        case .blurryPhoto:   return "Blurry"
        case .noSubject:     return "No Subject"
        case .lowLight:      return "Low Light"
        case .sharedPhoto:   return "Shared / Received"
        }
    }

    var icon: String {
        switch self {
        case .darkShot:      return "moon.fill"
        case .qrCode:        return "qrcode"
        case .screenPhoto:   return "desktopcomputer"
        case .whiteboard:    return "doc.text.fill"
        case .memeForwarded: return "arrow.2.squarepath"
        case .eyesClosed:    return "eye.slash"
        case .blurryPhoto:   return "camera.filters"
        case .noSubject:     return "scope"
        case .lowLight:      return "moon.stars"
        case .sharedPhoto:   return "arrow.down.circle"
        }
    }

    var color: Color {
        switch self {
        case .darkShot:      return Color(red: 0.55, green: 0.40, blue: 1.0)  // purple
        case .qrCode:        return Color(red: 0.20, green: 0.75, blue: 0.95) // cyan
        case .screenPhoto:   return Color(red: 0.30, green: 0.85, blue: 0.55) // green
        case .whiteboard:    return Color(red: 1.00, green: 0.70, blue: 0.20) // amber
        case .memeForwarded: return Color(red: 1.00, green: 0.40, blue: 0.55) // pink
        case .eyesClosed:    return Color(red: 1.00, green: 0.55, blue: 0.20) // orange
        case .blurryPhoto:   return Color(red: 0.95, green: 0.25, blue: 0.25) // red
        case .noSubject:     return Color(red: 0.55, green: 0.55, blue: 0.60) // gray
        case .lowLight:      return Color(red: 0.30, green: 0.30, blue: 0.70) // indigo
        case .sharedPhoto:   return Color(red: 0.20, green: 0.70, blue: 0.70) // teal
        }
    }
}
