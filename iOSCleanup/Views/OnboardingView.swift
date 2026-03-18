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
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "iphone.gen3.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)
            Text("Clean Up Your iPhone")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Find duplicate photos, merge contacts, and free up space from large videos — all on-device, never uploaded.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            OnboardingPrimaryButton(title: "Get Started", color: .blue, action: onNext)
        }
        .padding(.bottom, 60)
    }
}

// MARK: - Step 2: Photo Permission

private struct PhotoPermissionStep: View {
    let onNext: () -> Void
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 80))
                .foregroundStyle(.orange)
            Text("Photo Access")
                .font(.largeTitle.bold())
            Text("iOSCleanup scans your photos locally to find duplicates. Nothing leaves your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            if status == .denied || status == .restricted {
                OnboardingPrimaryButton(title: "Open Settings", color: .orange) {
                    if let url = URL(string: "app-settings:") { openURL(url) }
                }
            } else if status == .notDetermined {
                OnboardingPrimaryButton(title: "Allow Photo Access", color: .orange) {
                    Task {
                        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                        if status == .authorized || status == .limited { onNext() }
                    }
                }
            } else {
                OnboardingPrimaryButton(title: "Continue", color: .orange, action: onNext)
            }
            Button("Skip for now", action: onNext)
                .foregroundStyle(.secondary)
                .padding(.bottom, 60)
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Step 3: Contact Permission

private struct ContactPermissionStep: View {
    let onDone: () -> Void
    @State private var status = CNContactStore.authorizationStatus(for: .contacts)
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.2.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
            Text("Contacts Access")
                .font(.largeTitle.bold())
            Text("iOSCleanup finds duplicate contacts by matching phone numbers and names. No data is shared.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            if status == .denied || status == .restricted {
                OnboardingPrimaryButton(title: "Open Settings", color: .green) {
                    if let url = URL(string: "app-settings:") { openURL(url) }
                }
            } else if status == .notDetermined {
                OnboardingPrimaryButton(title: "Allow Contacts Access", color: .green) {
                    Task {
                        let store = CNContactStore()
                        _ = try? await store.requestAccess(for: .contacts)
                        status = CNContactStore.authorizationStatus(for: .contacts)
                        onDone()
                    }
                }
            } else {
                OnboardingPrimaryButton(title: "Done", color: .green, action: onDone)
            }
            Button("Skip for now", action: onDone)
                .foregroundStyle(.secondary)
                .padding(.bottom, 60)
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Shared button style

private struct OnboardingPrimaryButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(color)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 32)
    }
}
