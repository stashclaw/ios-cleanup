import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    private let features: [(icon: String, text: String)] = [
        ("photo.stack.fill",            "Bulk auto-clean duplicate photos"),
        ("person.2.fill",               "Merge duplicate contacts"),
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
                            .shadow(color: Color.duckPink.opacity(0.24), radius: 18, x: 0, y: 10)
                        PhotoDuckBrandLockup(wordmarkHeight: 38, showsIcon: false)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 8) {
                        Text("Unlock PhotoDuck")
                            .font(.duckDisplay)
                            .foregroundStyle(Color.duckBerry)
                        Text("One-time purchase · No subscription")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                        Text("Keep Best and individual Duck Mode decisions stay free.")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckBerry)
                            .multilineTextAlignment(.center)
                    }

                    // Feature list
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(features, id: \.text) { feature in
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(Color.duckPink)
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(Color.white)
                                }
                                Text(feature.text)
                                    .font(.duckBody)
                                    .foregroundStyle(Color.duckBerry)
                            }
                        }
                    }
                    .padding(.horizontal, 32)

                    // Error
                    if let error = purchaseManager.errorMessage {
                        VStack(spacing: 8) {
                            Text(error)
                                .font(.duckCaption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)

                            if purchaseManager.product == nil {
                                Button("Try Again") {
                                    Task { await purchaseManager.loadProduct() }
                                }
                                .font(.duckCaption.weight(.semibold))
                                .foregroundStyle(Color.duckRose)
                            }
                        }
                        .padding(.horizontal)
                    }

                    if let message = purchaseManager.statusMessage {
                        Text(message)
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckBerry)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Price
                    if let price = purchaseManager.product?.displayPrice {
                        Text(price)
                            .font(Font.custom("FredokaOne-Regular", size: 28))
                            .foregroundStyle(Color.duckPink)
                    }

                    // Unlock button
                    Group {
                        if purchaseManager.isLoading {
                            HStack { ProgressView().tint(Color.white) }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(
                                    LinearGradient(
                                        colors: [Color.duckPink, Color.duckRose],
                                        startPoint: .leading, endPoint: .trailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 50)
                                )
                        } else {
                            DuckPrimaryButton(title: "Unlock PhotoDuck") {
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
                    .foregroundStyle(Color.duckRose)
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
                    .foregroundStyle(Color.duckRose)
                    .padding(.bottom, 32)
                }
            }
            .background(Color.duckCream.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.duckRose)
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
                    body: "PhotoDuck analyzes photos, videos, and contacts on your device. It does not upload, sell, or share your personal content."
                )
                policySection(
                    title: "Photo and contact access",
                    body: "Photo access is used to create review groups, perform deletions you approve, and save compressed copies. Contact access is used only to find and merge entries you approve."
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
                    .foregroundStyle(Color.duckRose)
            }
            .padding(24)
        }
        .background(Color.duckCream.ignoresSafeArea())
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policySection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.duckBody.weight(.semibold))
                .foregroundStyle(Color.duckBerry)
            Text(body)
                .font(.duckBody)
                .foregroundStyle(Color.duckRose)
        }
    }
}
