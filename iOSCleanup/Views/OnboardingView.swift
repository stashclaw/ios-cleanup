import SwiftUI
import Photos

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            WelcomeStep(onNext: { page = 1 })
                .tag(0)
            PhotoPermissionStep(onDone: { hasOnboarded = true })
                .tag(1)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(Color.duckBlush.ignoresSafeArea())
        .onAppear {
            UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(
                red: 0.973, green: 0.373, blue: 0.639, alpha: 1) // DuckPink
            UIPageControl.appearance().pageIndicatorTintColor = UIColor(
                red: 0.973, green: 0.373, blue: 0.639, alpha: 0.3)
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.duckSoftPink)
                .frame(width: 180, height: 180)

            VStack(spacing: 10) {
                Text("Welcome to PhotoDuck!")
                    .font(.duckDisplay)
                    .foregroundStyle(Color.duckBerry)
                    .multilineTextAlignment(.center)
                Text("Time to tidy up your camera roll!")
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
                    .multilineTextAlignment(.center)
            }

            Spacer()
            DuckPrimaryButton(title: "Get Started", action: onNext)
                .padding(.horizontal, 32)
                .padding(.bottom, 60)
        }
    }
}

// MARK: - Step 2: Photo Permission

private struct PhotoPermissionStep: View {
    let onDone: () -> Void
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.duckSoftPink)
                .frame(width: 180, height: 180)

            VStack(spacing: 10) {
                Text("Duplicates Found!")
                    .font(.duckDisplay)
                    .foregroundStyle(Color.duckBerry)
                    .multilineTextAlignment(.center)
                Text("We'll find similar photos for you to review.")
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                if status == .denied || status == .restricted {
                    DuckPrimaryButton(title: "Open Settings") {
                        if let url = URL(string: "app-settings:") { openURL(url) }
                    }
                } else if status == .notDetermined {
                    DuckPrimaryButton(title: "Allow Photos Access") {
                        Task {
                            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                            if status == .authorized || status == .limited { onDone() }
                        }
                    }
                } else {
                    DuckPrimaryButton(title: "Continue", action: onDone)
                }
                Button("Skip for now", action: onDone)
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
        }
    }
}
