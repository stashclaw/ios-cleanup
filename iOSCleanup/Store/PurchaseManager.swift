import StoreKit
import SwiftUI

extension Notification.Name {
    static let purchaseDidSucceed = Notification.Name("purchaseDidSucceed")
}

@MainActor
final class PurchaseManager: ObservableObject {

    static let productID = "com.photoduck.app.unlock"
    private static let purchaseCacheKey = "isPurchased"

    enum EntitlementStatus: Equatable {
        case unknown
        case checking
        case entitled
        case notPurchased
        case usingCachedEntitlement
    }

    @Published private(set) var isPurchased: Bool
    @Published private(set) var entitlementStatus: EntitlementStatus = .unknown
    @Published private(set) var product: Product?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?

    private let defaults: UserDefaults
    private var transactionListenerTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isPurchased = defaults.bool(forKey: Self.purchaseCacheKey)
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
            if product == nil {
                errorMessage = "The PhotoDuck unlock is temporarily unavailable. Check your connection and try again."
            }
        } catch {
            errorMessage = "Could not load product: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product else {
            errorMessage = "The PhotoDuck unlock is not available yet. Try loading it again."
            return
        }
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        defer { isLoading = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                applyVerified(transaction)
                await transaction.finish()
            case .pending:
                statusMessage = "Purchase pending approval. PhotoDuck will unlock automatically when it is approved."
            case .userCancelled:
                break
            @unknown default:
                statusMessage = "The purchase did not complete. Please try again."
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Restore

    func restore() async {
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            let foundPurchase = await refreshEntitlement(allowDefinitiveMissing: true)
            if foundPurchase {
                DuckHaptics.success()
            } else {
                statusMessage = "No PhotoDuck purchase was found for this Apple Account."
            }
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Entitlement check (called on launch and after transactions)

    func updatePurchaseStatus() async {
        _ = await refreshEntitlement(allowDefinitiveMissing: false)
    }

    /// Returns whether a verified active entitlement was found.
    ///
    /// An empty launch-time entitlement sequence is not enough evidence to revoke a
    /// cached purchase. StoreKit can be temporarily inconclusive while offline or
    /// signed out, so only a verified revocation or a successful explicit restore
    /// may downgrade an existing purchaser.
    private func refreshEntitlement(allowDefinitiveMissing: Bool) async -> Bool {
        entitlementStatus = .checking

        for await result in currentEntitlements() {
            switch result {
            case .verified(let transaction):
                guard transaction.productID == Self.productID else { continue }
                if transaction.revocationDate == nil {
                    applyVerified(transaction, postSuccessNotification: false)
                    return true
                }
                setPurchased(false, status: .notPurchased)
                return false
            case .unverified(let transaction, _):
                guard transaction.productID == Self.productID else { continue }
                preserveCachedEntitlement()
                return false
            }
        }

        if let latest = await StoreKit.Transaction.latest(for: Self.productID) {
            switch latest {
            case .verified(let transaction):
                if transaction.revocationDate == nil {
                    applyVerified(transaction, postSuccessNotification: false)
                    return true
                }
                setPurchased(false, status: .notPurchased)
                return false
            case .unverified:
                preserveCachedEntitlement()
                return false
            }
        }

        if allowDefinitiveMissing {
            setPurchased(false, status: .notPurchased)
        } else {
            preserveCachedEntitlement()
        }
        return false
    }

    // MARK: - Background transaction listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                switch result {
                case .verified(let transaction):
                    if transaction.productID == Self.productID {
                        self.applyVerified(transaction)
                    }
                    await transaction.finish()
                case .unverified(let transaction, _):
                    if transaction.productID == Self.productID {
                        self.errorMessage = "A StoreKit update could not be verified. Your current access has not changed."
                        self.preserveCachedEntitlement()
                    }
                }
            }
        }
    }

    private func currentEntitlements() -> StoreKit.Transaction.Transactions {
        if #available(iOS 18.4, *) {
            return StoreKit.Transaction.currentEntitlements(for: Self.productID)
        }
        return StoreKit.Transaction.currentEntitlements
    }

    private func applyVerified(
        _ transaction: StoreKit.Transaction,
        postSuccessNotification: Bool = true
    ) {
        guard transaction.productID == Self.productID else { return }
        statusMessage = nil

        if transaction.revocationDate != nil {
            setPurchased(false, status: .notPurchased)
            return
        }

        setPurchased(true, status: .entitled)
        if postSuccessNotification {
            DuckHaptics.success()
            NotificationCenter.default.post(name: .purchaseDidSucceed, object: nil)
        }
    }

    private func preserveCachedEntitlement() {
        entitlementStatus = isPurchased ? .usingCachedEntitlement : .unknown
    }

    private func setPurchased(_ purchased: Bool, status: EntitlementStatus) {
        isPurchased = purchased
        entitlementStatus = status
        defaults.set(purchased, forKey: Self.purchaseCacheKey)
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
