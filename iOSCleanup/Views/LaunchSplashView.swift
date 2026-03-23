import SwiftUI

@MainActor
final class StartupCoordinator: ObservableObject {
    enum Step: Int, CaseIterable {
        case wakingUp
        case checkingAccess
        case loadingStore
        case openingApp

        var title: String {
            switch self {
            case .wakingUp:
                return "Waking up PhotoDuck"
            case .checkingAccess:
                return "Checking purchase status"
            case .loadingStore:
                return "Loading store details"
            case .openingApp:
                return "Opening your library"
            }
        }

        var subtitle: String {
            switch self {
            case .wakingUp:
                return "Preparing the launch screen and brand artwork."
            case .checkingAccess:
                return "Verifying unlock status on this device."
            case .loadingStore:
                return "Fetching the paywall product for later use."
            case .openingApp:
                return "Finishing startup and handing off to the app."
            }
        }

        var progressTarget: Double {
            switch self {
            case .wakingUp:
                return 0.15
            case .checkingAccess:
                return 0.42
            case .loadingStore:
                return 0.74
            case .openingApp:
                return 0.94
            }
        }
    }

    @Published private(set) var currentStep: Step = .wakingUp
    @Published private(set) var progress: Double = 0
    @Published private(set) var isReady = false

    private let purchaseManager: PurchaseManager
    private var didStart = false

    init(purchaseManager: PurchaseManager) {
        self.purchaseManager = purchaseManager
    }

    func start() async {
        guard !didStart else { return }
        didStart = true

        let startDate = Date()

        await advance(to: .wakingUp)
        try? await Task.sleep(nanoseconds: 220_000_000)

        await advance(to: .checkingAccess)
        await purchaseManager.updatePurchaseStatus()

        await advance(to: .loadingStore)
        await purchaseManager.loadProduct()

        await advance(to: .openingApp)

        let minimumDuration: TimeInterval = 2.2
        let elapsed = Date().timeIntervalSince(startDate)
        if elapsed < minimumDuration {
            let remaining = minimumDuration - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            progress = 1.0
        }

        try? await Task.sleep(nanoseconds: 180_000_000)
        isReady = true
    }

    private func advance(to step: Step) async {
        withAnimation(.easeInOut(duration: 0.35)) {
            currentStep = step
            progress = step.progressTarget
        }

        try? await Task.sleep(nanoseconds: 140_000_000)
    }
}

struct StartupGateView: View {
    @StateObject private var coordinator: StartupCoordinator

    init(purchaseManager: PurchaseManager) {
        _coordinator = StateObject(wrappedValue: StartupCoordinator(purchaseManager: purchaseManager))
    }

    var body: some View {
        ZStack {
            if coordinator.isReady {
                ContentView()
                    .transition(.opacity)
            }

            if !coordinator.isReady {
                LaunchSplashView(coordinator: coordinator)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.isReady)
        .task { await coordinator.start() }
    }
}

private struct LaunchSplashView: View {
    @ObservedObject var coordinator: StartupCoordinator

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.duckBlush, Color.white, Color.duckCream],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.duckPink.opacity(0.18))
                .frame(width: 260, height: 260)
                .blur(radius: 12)
                .offset(x: -120, y: -260)

            Circle()
                .fill(Color.duckYellow.opacity(0.20))
                .frame(width: 220, height: 220)
                .blur(radius: 20)
                .offset(x: 128, y: 250)

            VStack(spacing: 20) {
                Spacer(minLength: 16)

                splashArt

                VStack(spacing: 8) {
                    Text("PhotoDuck")
                        .font(.duckDisplay)
                        .foregroundStyle(Color.duckBerry)

                    Text("Step \(coordinator.currentStep.rawValue + 1) of \(StartupCoordinator.Step.allCases.count)")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckPink)

                    Text(coordinator.currentStep.title)
                        .font(.duckHeading)
                        .foregroundStyle(Color.duckRose)
                        .multilineTextAlignment(.center)

                    Text(coordinator.currentStep.subtitle)
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose.opacity(0.86))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }

                progressCard

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
        }
    }

    private var splashArt: some View {
        Image("LaunchDuck")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 320)
            .frame(maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
            )
            .shadow(color: Color.duckPink.opacity(0.22), radius: 28, x: 0, y: 16)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Loading")
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)

                Spacer()

                Text("\(Int(coordinator.progress * 100))%")
                    .font(.duckBody)
                    .foregroundStyle(Color.duckBerry)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.duckSoftPink.opacity(0.30))

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.duckYellow, Color.duckPink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width * coordinator.progress)
                }
            }
            .frame(height: 14)

            VStack(spacing: 10) {
                ForEach(StartupCoordinator.Step.allCases, id: \.self) { step in
                    LaunchStepRow(
                        step: step,
                        isCurrent: step == coordinator.currentStep,
                        isComplete: step.rawValue < coordinator.currentStep.rawValue
                    )
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.74))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.duckSoftPink.opacity(0.34), lineWidth: 1)
                )
        )
    }
}

private struct LaunchStepRow: View {
    let step: StartupCoordinator.Step
    let isCurrent: Bool
    let isComplete: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(markerFill)
                    .frame(width: 28, height: 28)

                Image(systemName: markerIcon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(markerForeground)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.duckBody)
                    .foregroundStyle(Color.duckBerry)

                Text(step.subtitle)
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose.opacity(0.82))
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var markerFill: Color {
        if isComplete { return Color.duckPink }
        if isCurrent { return Color.duckYellow }
        return Color.duckSoftPink.opacity(0.55)
    }

    private var markerForeground: Color {
        if isComplete || isCurrent { return Color.white }
        return Color.duckRose
    }

    private var markerIcon: String {
        if isComplete { return "checkmark" }
        if isCurrent { return "arrow.triangle.2.circlepath" }
        return "circle"
    }
}
