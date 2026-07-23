import SwiftUI
import Photos
import Contacts

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            WelcomeStep(onNext: { page = 1 })
                .tag(0)
            PhotoPermissionStep(onNext: { page = 2 })
                .tag(1)
            ContactPermissionStep(onDone: { hasOnboarded = true })
                .tag(2)
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
            VStack(spacing: 18) {
                PhotoDuckIconMark(size: 180)
                    .shadow(color: Color.duckPink.opacity(0.24), radius: 22, x: 0, y: 12)
                PhotoDuckBrandLockup(wordmarkHeight: 38, showsIcon: false)
            }

            VStack(spacing: 10) {
                Text("Keep the best. Duck the rest.")
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
    let onNext: () -> Void
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            PhotoDuckMascotArt(size: 180)
                .shadow(color: Color.duckPink.opacity(0.18), radius: 20, x: 0, y: 12)

            VStack(spacing: 10) {
                Text("Find Photos to Review")
                    .font(.duckDisplay)
                    .foregroundStyle(Color.duckBerry)
                    .multilineTextAlignment(.center)
                Text("Allow access so PhotoDuck can compare photos and prepare review groups on your device.")
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
                            if status == .authorized || status == .limited { onNext() }
                        }
                    }
                } else {
                    DuckPrimaryButton(title: "Continue", action: onNext)
                }
                Button("Skip for now", action: onNext)
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
        }
    }
}

// MARK: - Step 3: Contact Permission

private struct ContactPermissionStep: View {
    let onDone: () -> Void
    @State private var status = CNContactStore.authorizationStatus(for: .contacts)
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            PhotoDuckMascotArt(size: 180)
                .shadow(color: Color.duckYellow.opacity(0.24), radius: 20, x: 0, y: 12)

            VStack(spacing: 10) {
                Text("Clean Up Contacts Too")
                    .font(.duckDisplay)
                    .foregroundStyle(Color.duckBerry)
                    .multilineTextAlignment(.center)
                Text("Contact access lets PhotoDuck find possible duplicates. You can skip this step.")
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
                    DuckPrimaryButton(title: "Allow Contacts Access") {
                        Task {
                            let store = CNContactStore()
                            _ = try? await store.requestAccess(for: .contacts)
                            status = CNContactStore.authorizationStatus(for: .contacts)
                            onDone()
                        }
                    }
                } else {
                    DuckPrimaryButton(title: "Let's Go", action: onDone)
                }
                Button("Skip for now", action: onDone)
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
        }
    }
}
