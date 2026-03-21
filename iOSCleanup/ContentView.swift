import SwiftUI

struct ContentView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @StateObject private var dashboardModel = HomeViewModel()
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if hasOnboarded {
            PhotoDuckShellView(dashboardModel: dashboardModel)
                .environmentObject(purchaseManager)
                .environmentObject(deletionManager)
                .onChange(of: scenePhase) { phase in
                    dashboardModel.updateScenePhase(phase)
                }
        } else {
            OnboardingView()
        }
    }
}
