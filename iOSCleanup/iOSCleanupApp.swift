import SwiftUI

@main
struct iOSCleanupApp: App {
    @StateObject private var purchaseManager = PurchaseManager()

    init() {
        BackgroundScanScheduler.registerAll()  // MUST be before first runloop tick
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(purchaseManager)
                .task {
                    await purchaseManager.updatePurchaseStatus()
                    BackgroundScanScheduler.scheduleIfNeeded()
                }
        }
    }

    private func configureAppearance() {
        // Navigation bar
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(red: 1, green: 0.973, blue: 0.984, alpha: 1) // #FFF8FB
        navAppearance.titleTextAttributes = [
            .font: UIFont(name: "FredokaOne-Regular", size: 18) ?? .systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: UIColor(red: 0.616, green: 0.235, blue: 0.400, alpha: 1) // #9D3C66
        ]
        navAppearance.largeTitleTextAttributes = [
            .font: UIFont(name: "FredokaOne-Regular", size: 28) ?? .systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: UIColor(red: 0.616, green: 0.235, blue: 0.400, alpha: 1) // #9D3C66
        ]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        // Tab bar
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(red: 1, green: 0.973, blue: 0.984, alpha: 1) // #FFF8FB
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().tintColor = UIColor(red: 0.973, green: 0.373, blue: 0.639, alpha: 1) // #F85FA3
        UITabBar.appearance().unselectedItemTintColor = UIColor(red: 0.788, green: 0.298, blue: 0.518, alpha: 0.5)

        // Table view
        UITableView.appearance().backgroundColor = UIColor(red: 1, green: 0.949, blue: 0.973, alpha: 1) // #FFF2F8
    }
}
