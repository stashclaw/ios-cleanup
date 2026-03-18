import SwiftUI

extension Notification.Name {
    static let purchaseDidSucceed = Notification.Name("purchaseDidSucceed")
}

struct PaywallView: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    private let features: [(icon: String, text: String)] = [
        ("trash.fill",         "Bulk delete duplicate photos"),
        ("person.2.fill",      "Merge duplicate contacts"),
        ("arrow.triangle.2.circlepath", "Compress videos to save space"),
        ("checkmark.seal.fill","One-time unlock — no subscription"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Hero
                    VStack(spacing: 8) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue)
                        Text("Unlock iOSCleanup")
                            .font(.title.bold())
                        Text("Everything you need to clean your phone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    // Feature list
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(features, id: \.text) { feature in
                            HStack(spacing: 14) {
                                Image(systemName: feature.icon)
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                    .frame(width: 28)
                                Text(feature.text)
                                    .font(.body)
                            }
                        }
                    }
                    .padding(.horizontal, 32)

                    // Error
                    if let error = purchaseManager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Unlock button
                    Button(action: {
                        Task {
                            await purchaseManager.purchase()
                            if purchaseManager.isPurchased {
                                NotificationCenter.default.post(name: .purchaseDidSucceed, object: nil)
                                dismiss()
                            }
                        }
                    }) {
                        Group {
                            if purchaseManager.isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(unlockLabel)
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .disabled(purchaseManager.isLoading)

                    Text("One-time purchase. No subscription.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            if purchaseManager.product == nil {
                await purchaseManager.loadProduct()
            }
        }
    }

    private var unlockLabel: String {
        if let price = purchaseManager.product?.displayPrice {
            return "Unlock for \(price)"
        }
        return "Unlock"
    }
}
