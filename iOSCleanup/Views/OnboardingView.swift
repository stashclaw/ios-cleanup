import SwiftUI
import Photos

struct OnboardingView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            WelcomeStep(onNext: { page = 1 })
                .tag(0)
            PhotoPermissionStep(onNext: { hasOnboarded = true })
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.backgroundBlush.ignoresSafeArea())
        // Local page dots instead of a global UIPageControl.appearance()
        // override: every screen owns its own chrome, and the dots use the
        // accent token rather than hard-coded RGB.
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .fill(Color.accentPrimary.opacity(index == page ? 1 : 0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 16)
            .animation(.duckSpring, value: page)
            .accessibilityHidden(true)
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
                    .shadow(color: Color.accentPrimary.opacity(0.24), radius: 22, x: 0, y: 12)
                PhotoDuckBrandLockup(wordmarkHeight: 38, showsIcon: false)
            }

            VStack(spacing: 10) {
                Text("Keep the best. Duck the rest.")
                    .font(.duckDisplay)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Time to tidy up your camera roll.")
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
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
                .shadow(color: Color.accentPrimary.opacity(0.18), radius: 20, x: 0, y: 12)

            VStack(spacing: 10) {
                Text("Find Photos to Review")
                    .font(.duckDisplay)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Allow access so PhotoDuck can compare photos and prepare review groups on your device.")
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
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
                    .foregroundStyle(Color.textSecondary)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
        }
    }
}

