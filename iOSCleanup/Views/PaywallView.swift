import SwiftUI

extension Notification.Name {
    static let purchaseDidSucceed = Notification.Name("purchaseDidSucceed")
}

struct PaywallView: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    private let features: [(icon: String, text: String)] = [
        ("photo.stack.fill",            "Bulk delete duplicate photos"),
        ("person.2.fill",               "Merge duplicate contacts"),
        ("arrow.triangle.2.circlepath", "Compress videos to save space"),
        ("iphone.gen3",                 "100% on-device — nothing uploaded"),
        ("checkmark.seal.fill",         "One-time unlock · No subscription"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Hero placeholder
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.duckSoftPink)
                        .frame(width: 140, height: 140)
                        .padding(.top, 8)

                    VStack(spacing: 8) {
                        Text("Unlock PhotoDuck")
                            .font(.duckDisplay)
                            .foregroundStyle(Color.duckBerry)
                        Text("One-time purchase · No subscription")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
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
                        Text(error)
                            .font(.duckCaption)
                            .foregroundStyle(.red)
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
                                        colors: [Color.duckPink, Color(red: 0.831, green: 0.271, blue: 0.541)],
                                        startPoint: .leading, endPoint: .trailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 50)
                                )
                        } else {
                            DuckPrimaryButton(title: "Unlock PhotoDuck") {
                                Task {
                                    await purchaseManager.purchase()
                                    if purchaseManager.isPurchased {
                                        NotificationCenter.default.post(name: .purchaseDidSucceed, object: nil)
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
                                NotificationCenter.default.post(name: .purchaseDidSucceed, object: nil)
                                dismiss()
                            }
                        }
                    }
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
                    .disabled(purchaseManager.isLoading)
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
    }
}
