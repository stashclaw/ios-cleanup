import SwiftUI
import UserNotifications

@main
struct iOSCleanupApp: App {
    @StateObject private var purchaseManager = PurchaseManager()
    @StateObject private var deletionManager = DeletionManager()
    private let notificationRouter = CleanupNotificationRouter()

    init() {
        VideoCompressionEngine.performStartupCleanup()
        configureAppearance()
        UNUserNotificationCenter.current().delegate = notificationRouter
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .deletionUndoToast()
                .environmentObject(purchaseManager)
                .environmentObject(deletionManager)
                .environmentObject(notificationRouter)
                .task { await purchaseManager.updatePurchaseStatus() }
        }
    }

    private func configureAppearance() {
        let primaryTint = UIColor(named: "DuckPink") ?? .systemPink
        let secondaryTint = UIColor(named: "DuckRose") ?? .secondaryLabel
        UINavigationBar.appearance().tintColor = primaryTint

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().tintColor = primaryTint
        UITabBar.appearance().unselectedItemTintColor = secondaryTint.withAlphaComponent(0.5)
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
