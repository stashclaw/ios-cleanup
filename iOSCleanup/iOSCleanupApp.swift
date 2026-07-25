import SwiftUI
import UIKit
import UserNotifications

@main
struct iOSCleanupApp: App {
    @StateObject private var purchaseManager = PurchaseManager()
    @StateObject private var deletionManager = DeletionManager()
    @StateObject private var exportAlbum = ExportAlbumStore()
    private let notificationRouter = CleanupNotificationRouter()

    init() {
        VideoCompressionEngine.performStartupCleanup()
        UNUserNotificationCenter.current().delegate = notificationRouter
    }

    // No global UIKit appearance chrome: each screen owns its own
    // `.toolbarBackground` / `.toolbarColorScheme`, and tint flows from here.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Color.accentPrimary)
                .deletionUndoToast()
                .environmentObject(purchaseManager)
                .environmentObject(deletionManager)
                .environmentObject(exportAlbum)
                .environmentObject(notificationRouter)
                .task { await purchaseManager.updatePurchaseStatus() }
                .task { await AssetFileSizeRepository.shared.warmMemoryCache() }
                .task {
                    await ExportLiveActivityController
                        .endOrphanedActivities()
                }
                .task {
                    let info = Bundle.main.infoDictionary
                    await PhotoDuckDiagnosticLog.shared
                        .performStartupMaintenance()
                    await PhotoDuckDiagnosticLog.shared.record(
                        .appLaunched(
                            appVersion:
                                info?["CFBundleShortVersionString"] as? String
                                    ?? "unknown",
                            buildVersion:
                                info?["CFBundleVersion"] as? String
                                    ?? "unknown",
                            osVersion:
                                "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                        )
                    )
                }
        }
    }
}

final class CleanupNotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    enum Target: String {
        case reviewResults
    }

    @Published var pendingTarget: Target?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let targetValue = response.notification.request.content.userInfo["cleanupTarget"] as? String,
           let target = Target(rawValue: targetValue) {
            DispatchQueue.main.async { [weak self] in
                self?.pendingTarget = target
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The in-app scan UI already communicates progress and completion.
        completionHandler([])
    }
}
