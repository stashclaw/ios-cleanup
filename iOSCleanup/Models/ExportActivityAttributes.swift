import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared between the app and the PhotoDuckWidgets extension. Keep this file
/// free of PhotoKit and app-only dependencies so it can be a member of both
/// targets.
struct PhotoDuckExportActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case exporting
            case paused
            case finished
            case completedWithFailures
            case cancelled
            case failed
        }

        var completedFileCount: Int
        var totalFileCount: Int
        var currentFilename: String?
        var overallFraction: Double
        var phase: Phase

        var statusLine: String {
            switch phase {
            case .exporting:
                guard totalFileCount > 0 else {
                    return "Preparing export…"
                }
                let position = min(completedFileCount + 1, max(totalFileCount, 1))
                return "File \(position) of \(totalFileCount)"
            case .paused:
                return "Paused — open PhotoDuck to continue"
            case .finished:
                return "\(totalFileCount) files exported and verified"
            case .completedWithFailures:
                return "Verified files saved — some items need attention"
            case .cancelled:
                return "Export cancelled"
            case .failed:
                return "Export couldn't finish"
            }
        }
    }

    /// The folder the export is writing into, for display only.
    var destinationName: String
}
#endif
