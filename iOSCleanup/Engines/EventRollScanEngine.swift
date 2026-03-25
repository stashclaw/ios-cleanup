import Photos
import CoreLocation

// MARK: - Event enum

enum EventRollScanEvent: Sendable {
    case progress(completed: Int, total: Int)
    case rollsFound([EventRoll])
}

// MARK: - Engine

actor EventRollScanEngine {

    // Clustering thresholds
    private static let timeGapThreshold:     TimeInterval = 30 * 60   // 30 minutes
    private static let distanceKmThreshold:  Double       = 1.0       // 1 km
    private static let minPhotosPerRoll:     Int          = 5
    private static let minRollDuration:      TimeInterval = 5 * 60    // 5 minutes

    nonisolated func scan() -> AsyncThrowingStream<EventRollScanEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let assets = try await self.fetchAssets()
                    let total  = assets.count
                    var completed = 0

                    // MARK: Phase 1 — cluster into raw rolls (greedy single-pass)

                    // Each roll accumulates: assets, running centroid, latest date.
                    struct RawRoll {
                        var assets: [PHAsset]
                        var latSumDeg: Double    // sum of latitudes (degrees) for centroid
                        var lonSumDeg: Double
                        var gpsCounted: Int      // number of assets with GPS
                        var startDate: Date
                        var latestDate: Date

                        var centroid: CLLocationCoordinate2D? {
                            guard gpsCounted > 0 else { return nil }
                            return CLLocationCoordinate2D(
                                latitude:  latSumDeg / Double(gpsCounted),
                                longitude: lonSumDeg / Double(gpsCounted)
                            )
                        }
                    }

                    var rolls: [RawRoll] = []

                    for asset in assets {
                        guard !Task.isCancelled else { break }

                        let date = asset.creationDate ?? Date.distantPast
                        let coord: CLLocationCoordinate2D? = asset.location?.coordinate

                        var assignedRollIndex: Int? = nil

                        // Check if we should continue the last (most recent) roll.
                        if var last = rolls.last {
                            let timeGap = date.timeIntervalSince(last.latestDate)

                            // Time gate: > 30 min always starts a new roll.
                            if timeGap <= Self.timeGapThreshold {
                                // Distance gate: if asset and roll centroid both have GPS,
                                // check they're within 1 km.
                                var withinDistance = true
                                if let c = coord, let center = last.centroid {
                                    withinDistance = Self.haversineKm(center, c) <= Self.distanceKmThreshold
                                }

                                if withinDistance {
                                    last.assets.append(asset)
                                    last.latestDate = date
                                    if let c = coord {
                                        last.latSumDeg  += c.latitude
                                        last.lonSumDeg  += c.longitude
                                        last.gpsCounted += 1
                                    }
                                    rolls[rolls.count - 1] = last
                                    assignedRollIndex = rolls.count - 1
                                }
                            }
                        }

                        if assignedRollIndex == nil {
                            var r = RawRoll(
                                assets:     [asset],
                                latSumDeg:  0, lonSumDeg: 0, gpsCounted: 0,
                                startDate:  date,
                                latestDate: date
                            )
                            if let c = coord {
                                r.latSumDeg  = c.latitude
                                r.lonSumDeg  = c.longitude
                                r.gpsCounted = 1
                            }
                            rolls.append(r)
                        }

                        completed += 1
                        if completed % 40 == 0 || completed == total {
                            continuation.yield(.progress(completed: completed, total: total))
                        }
                    }

                    // MARK: Phase 2 — filter noise

                    let validRolls = rolls.filter { roll in
                        guard roll.assets.count >= Self.minPhotosPerRoll else { return false }
                        let span = roll.latestDate.timeIntervalSince(roll.startDate)
                        return span >= Self.minRollDuration
                    }

                    // MARK: Phase 3 — reverse-geocode centroids (rate-limited)

                    var eventRolls: [EventRoll] = []
                    let geocoder = CLGeocoder()

                    for roll in validRolls {
                        guard !Task.isCancelled else { break }

                        var locationName: String? = nil

                        if let centroid = roll.centroid {
                            let location = CLLocation(latitude: centroid.latitude,
                                                      longitude: centroid.longitude)
                            if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
                               let pm = placemarks.first {
                                let parts = [pm.locality, pm.country].compactMap { $0 }
                                if !parts.isEmpty {
                                    locationName = parts.joined(separator: ", ")
                                }
                            }
                            // Apple geocoder rate-limit: ~1 request per 0.5 s.
                            try await Task.sleep(nanoseconds: 500_000_000)
                        }

                        let er = EventRoll(
                            id:                  UUID(),
                            assets:              roll.assets,
                            startDate:           roll.startDate,
                            endDate:             roll.latestDate,
                            locationName:        locationName,
                            approximateLocation: roll.centroid
                        )
                        eventRolls.append(er)
                    }

                    // Sort most recent first.
                    eventRolls.sort { $0.startDate > $1.startDate }

                    continuation.yield(.rollsFound(eventRolls))
                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func fetchAssets() async throws -> [PHAsset] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ScanError.permissionDenied
        }
        let options = PHFetchOptions()
        // Sort ascending — greedy clustering relies on chronological order.
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // All image types including screenshots, bursts, etc.
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Haversine great-circle distance in kilometres between two coordinates.
    /// Inline implementation — no CoreLocation distance APIs used.
    private static func haversineKm(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        let R    = 6371.0
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude  * .pi / 180
        let lat2 = b.latitude  * .pi / 180
        let x    = sin(dLat / 2) * sin(dLat / 2)
                 + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(x), sqrt(1 - x))
    }
}
