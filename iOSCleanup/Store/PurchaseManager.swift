import StoreKit
import SwiftUI

@MainActor
final class PurchaseManager: ObservableObject {

    static let productID = "com.photoduck.app.unlock"

    // Persisted cache — re-verified against StoreKit on every launch
    @AppStorage("isPurchased") private(set) var isPurchased: Bool = false

    @Published private(set) var product: Product?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    private var transactionListenerTask: Task<Void, Never>?

    init() {
        transactionListenerTask = listenForTransactions()
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Load product

    func loadProduct() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
        } catch {
            errorMessage = "Could not load product: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await updatePurchaseStatus()
                await transaction.finish()
            case .pending:
                break
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Restore

    func restore() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await updatePurchaseStatus()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Entitlement check (called on launch and after transactions)

    func updatePurchaseStatus() async {
        var purchased = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                purchased = true
                break
            }
        }
        isPurchased = purchased
    }

    // MARK: - Background transaction listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await self.updatePurchaseStatus()
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - Verification helper

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}
