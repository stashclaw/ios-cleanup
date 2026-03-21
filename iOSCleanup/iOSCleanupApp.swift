import SwiftUI
import UserNotifications

@main
struct iOSCleanupApp: App {
    @StateObject private var purchaseManager = PurchaseManager()
    @StateObject private var deletionManager = DeletionManager()
    private let notificationRouter = CleanupNotificationRouter()

    init() {
        configureAppearance()
        UNUserNotificationCenter.current().delegate = notificationRouter
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(purchaseManager)
                .environmentObject(deletionManager)
                .environmentObject(notificationRouter)
                .task { await purchaseManager.updatePurchaseStatus() }
                .overlay(alignment: .bottom) {
                    if deletionManager.toastVisible {
                        UndoToast(
                            toastID: deletionManager.toastID,
                            freedBytes: deletionManager.toastFreedBytes,
                            freedCount: deletionManager.toastFreedCount,
                            onUndo: { deletionManager.undoLast() },
                            onDismiss: { deletionManager.toastVisible = false }
                        )
                        .padding(.bottom, 24 + 49)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(999)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: deletionManager.toastVisible)
        }
    }

    private func configureAppearance() {
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(red: 1, green: 0.973, blue: 0.984, alpha: 1)
        navAppearance.titleTextAttributes = [
            .font: UIFont(name: "FredokaOne-Regular", size: 18) ?? .systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: UIColor(red: 0.616, green: 0.235, blue: 0.400, alpha: 1)
        ]
        navAppearance.largeTitleTextAttributes = [
            .font: UIFont(name: "FredokaOne-Regular", size: 28) ?? .systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: UIColor(red: 0.616, green: 0.235, blue: 0.400, alpha: 1)
        ]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(red: 1, green: 0.973, blue: 0.984, alpha: 1)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().tintColor = UIColor(red: 0.973, green: 0.373, blue: 0.639, alpha: 1)
        UITabBar.appearance().unselectedItemTintColor = UIColor(red: 0.788, green: 0.298, blue: 0.518, alpha: 0.5)

        UITableView.appearance().backgroundColor = UIColor(red: 1, green: 0.949, blue: 0.973, alpha: 1)
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
        completionHandler([.banner, .sound])
    }
}
