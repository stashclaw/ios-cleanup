import SwiftUI

@main
struct iOSCleanupApp: App {
    @StateObject private var purchaseManager = PurchaseManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(purchaseManager)
                .task { await purchaseManager.updatePurchaseStatus() }
        }
    }
}
