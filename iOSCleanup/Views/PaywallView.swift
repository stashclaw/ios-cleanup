import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    private let features: [(icon: String, text: String)] = [
        ("photo.stack.fill",            "Bulk auto-clean duplicate photos"),
        ("arrow.triangle.2.circlepath", "Compress videos to save space"),
        ("iphone.gen3",                 "On-device processing — nothing uploaded"),
        ("checkmark.seal.fill",         "One-time unlock · No subscription"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        PhotoDuckIconMark(size: 120)
                            .shadow(color: Color.accentPrimary.opacity(0.24), radius: 18, x: 0, y: 10)
                        PhotoDuckBrandLockup(wordmarkHeight: 38, showsIcon: false)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 8) {
                        Text("Unlock PhotoDuck")
                            .font(.duckDisplay)
                            .foregroundStyle(Color.textPrimary)
                        Text("One-time purchase · No subscription")
                            .font(.duckCaption)
                            .foregroundStyle(Color.textSecondary)
                        Text("Keep Best and individual Duck Mode decisions stay free.")
                            .font(.duckCaption)
                            .foregroundStyle(Color.textPrimary)
                            .multilineTextAlignment(.center)
                    }

                    // Feature list
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(features, id: \.text) { feature in
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentPrimary)
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "checkmark")
                                        .font(.duckLabel.weight(.bold))
                                        .foregroundStyle(Color.white)
                                }
                                Text(feature.text)
                                    .font(.duckBody)
                                    .foregroundStyle(Color.textPrimary)
                            }
                        }
                    }
                    .padding(.horizontal, 32)

                    // Error
                    if let error = purchaseManager.errorMessage {
                        VStack(spacing: 8) {
                            Text(error)
                                .font(.duckCaption)
                                .foregroundStyle(Color.danger)
                                .multilineTextAlignment(.center)

                            if purchaseManager.product == nil {
                                Button("Try Again") {
                                    Task { await purchaseManager.loadProduct() }
                                }
                                .font(.duckCaption.weight(.semibold))
                                .foregroundStyle(Color.textSecondary)
                            }
                        }
                        .padding(.horizontal)
                    }

                    if let message = purchaseManager.statusMessage {
                        Text(message)
                            .font(.duckCaption)
                            .foregroundStyle(Color.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Price
                    if let price = purchaseManager.product?.displayPrice {
                        Text(price)
                            .font(.duckDisplay)
                            .foregroundStyle(Color.accentPrimary)
                    }

                    // Unlock button — the loading state keeps the exact
                    // DuckPrimaryButton geometry so the CTA never morphs.
                    Group {
                        if purchaseManager.isLoading {
                            HStack { ProgressView().tint(Color.white) }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(
                                    LinearGradient.duckPrimaryCTA,
                                    in: Capsule(style: .continuous)
                                )
                                .duckPrimaryGlow()
                        } else {
                            DuckPrimaryButton(
                                title: purchaseManager.product == nil
                                    ? "Unlock Unavailable"
                                    : "Unlock PhotoDuck"
                            ) {
                                Task {
                                    await purchaseManager.purchase()
                                    if purchaseManager.isPurchased {
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                    .disabled(purchaseManager.isLoading || purchaseManager.product == nil)
                    // A disabled unlock that still looks tappable reads as a
                    // broken button; dim it so the Try Again path is obvious.
                    .opacity(purchaseManager.product == nil && !purchaseManager.isLoading ? 0.45 : 1)
                    .padding(.horizontal, 32)

                    // Restore
                    Button("Restore Purchase") {
                        Task {
                            await purchaseManager.restore()
                            if purchaseManager.isPurchased {
                                dismiss()
                            }
                        }
                    }
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
                    .disabled(purchaseManager.isLoading)
                    .frame(minHeight: 44)

                    HStack(spacing: 18) {
                        NavigationLink("Privacy Policy") {
                            PhotoDuckPrivacyPolicyView()
                        }
                        .frame(minHeight: 44)

                        Link("Terms of Use", destination: termsURL)
                            .frame(minHeight: 44)
                    }
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.bottom, 32)
                }
            }
            .background(Color.surface.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .task {
            if purchaseManager.product == nil {
                await purchaseManager.loadProduct()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            dismiss()
        }
    }
}

private struct PhotoDuckPrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                policySection(
                    title: "On-device processing",
                    body: "PhotoDuck analyzes photos and videos on your device. It does not upload, sell, or share your personal content."
                )
                policySection(
                    title: "Photo access",
                    body: "Photo access is used to create review groups, perform deletions you approve, and save compressed copies."
                )
                policySection(
                    title: "Purchases",
                    body: "Apple processes purchases. PhotoDuck reads StoreKit entitlement status to unlock paid features and stores a local entitlement cache for offline continuity."
                )
                policySection(
                    title: "Local data",
                    body: "Preferences, analysis caches, and optional learning data remain in the app container. Deleting PhotoDuck removes that local app data; photo-library changes remain managed by the Photos app."
                )

                Text("Last updated July 23, 2026")
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(24)
        }
        .background(Color.surface.ignoresSafeArea())
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policySection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.duckBody.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            Text(body)
                .font(.duckBody)
                .foregroundStyle(Color.textSecondary)
        }
    }
}
