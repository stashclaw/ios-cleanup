import Foundation
import Photos
import CoreLocation

struct EventRoll: Identifiable, Sendable {
    let id: UUID
    let assets: [PHAsset]          // sorted by creationDate ascending
    let startDate: Date
    let endDate: Date
    let locationName: String?      // reverse-geocoded display name, nil if no GPS
    let approximateLocation: CLLocationCoordinate2D?

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
    var photoCount: Int { assets.count }
}

// CLLocationCoordinate2D is a C struct — not automatically Sendable.
// It contains only two Doubles, making it safe to cross concurrency boundaries.
extension CLLocationCoordinate2D: @retroactive @unchecked Sendable {}
