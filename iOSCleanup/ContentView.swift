import SwiftUI

struct ContentView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @StateObject private var dashboardModel = HomeViewModel()
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if hasOnboarded {
                PhotoDuckShellView(dashboardModel: dashboardModel)
                    .environmentObject(purchaseManager)
                    .environmentObject(deletionManager)
                    .onAppear {
                        // The model is created while onboarding is still on
                        // screen; run its deferred startup once the user has
                        // answered the permission prompts.
                        dashboardModel.bootstrapLibraryStateIfNeeded()
                    }
                    .onChange(of: scenePhase) { phase in
                        dashboardModel.updateScenePhase(phase)
                    }
            } else {
                OnboardingView()
            }
        }
        .preferredColorScheme(.light)  // deliberate lock — light mode is the brand
    }
}
