import StoreKit
import SwiftUI

extension Notification.Name {
    static let purchaseDidSucceed = Notification.Name("purchaseDidSucceed")
}

// MARK: - Entitlement seam

/// A verification-agnostic snapshot of one StoreKit entitlement record.
///
/// `StoreKit.Transaction` and `VerificationResult` cannot be constructed by
/// tests, so the entitlement state machine reads this reduced view instead.
/// It carries exactly the two facts the state machine acts on: which product
/// the record belongs to, and whether a verified record has been revoked.
enum EntitlementRecord: Equatable, Sendable {
    case verified(productID: String, revocationDate: Date?)
    case unverified(productID: String)

    var productID: String {
        switch self {
        case .verified(let productID, _): return productID
        case .unverified(let productID): return productID
        }
    }

    init(_ result: VerificationResult<StoreKit.Transaction>) {
        switch result {
        case .verified(let transaction):
            self = .verified(
                productID: transaction.productID,
                revocationDate: transaction.revocationDate
            )
        case .unverified(let transaction, _):
            self = .unverified(productID: transaction.productID)
        }
    }
}

/// Injection point for the two static StoreKit entitlement queries.
protocol EntitlementSource: Sendable {
    func currentEntitlements(for productID: String) async -> [EntitlementRecord]
    func latestTransaction(for productID: String) async -> EntitlementRecord?
}

/// The production source. Wraps `StoreKit.Transaction.currentEntitlements` and
/// `StoreKit.Transaction.latest(for:)` without changing their semantics.
struct LiveEntitlementSource: EntitlementSource {

    func currentEntitlements(for productID: String) async -> [EntitlementRecord] {
        var records: [EntitlementRecord] = []
        for await result in Self.entitlementSequence(for: productID) {
            records.append(EntitlementRecord(result))
        }
        return records
    }

    func latestTransaction(for productID: String) async -> EntitlementRecord? {
        guard let latest = await StoreKit.Transaction.latest(for: productID) else { return nil }
        return EntitlementRecord(latest)
    }

    private static func entitlementSequence(
        for productID: String
    ) -> StoreKit.Transaction.Transactions {
        if #available(iOS 18.4, *) {
            return StoreKit.Transaction.currentEntitlements(for: productID)
        }
        return StoreKit.Transaction.currentEntitlements
    }
}

@MainActor
final class PurchaseManager: ObservableObject {

    static let productID = "com.photoduck.app.unlock"
    private static let purchaseCacheKey = "isPurchased"

    /// Kept as constants so a stale verification banner can be recognised and
    /// cleared once access is confirmed again.
    static let unverifiedUpdateMessage =
        "A StoreKit update could not be verified. Your current access has not changed."
    static let unverifiedPurchaseMessage =
        "That purchase could not be verified, so PhotoDuck was not unlocked. If you were charged, tap Restore Purchase."

#if DEBUG
    private static let adminAccessKey = "photoduck.debug-admin-access"
#endif

    enum EntitlementStatus: Equatable {
        case unknown
        case checking
        case entitled
        case notPurchased
        case usingCachedEntitlement
#if DEBUG
        case adminUnlocked
#endif
    }

    @Published private(set) var isPurchased: Bool
#if DEBUG
    @Published private(set) var isAdminAccessEnabled: Bool
#endif
    @Published private(set) var entitlementStatus: EntitlementStatus = .unknown
    @Published private(set) var product: Product?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?

    private let defaults: UserDefaults
    private let entitlementSource: any EntitlementSource
    private var hasStoreEntitlement: Bool
    private var transactionListenerTask: Task<Void, Never>?
    /// Unverified updates are surfaced at most once each, so a repeated
    /// delivery can never pin a permanent error banner to the paywall.
    private var reportedUnverifiedTransactionIDs: Set<UInt64> = []

    init(
        defaults: UserDefaults = .standard,
        entitlementSource: any EntitlementSource = LiveEntitlementSource(),
        observesTransactionUpdates: Bool = true
    ) {
        self.defaults = defaults
        self.entitlementSource = entitlementSource
        let cachedStoreEntitlement = defaults.bool(forKey: Self.purchaseCacheKey)
        hasStoreEntitlement = cachedStoreEntitlement
#if DEBUG
        let cachedAdminAccess = defaults.bool(forKey: Self.adminAccessKey)
        isAdminAccessEnabled = cachedAdminAccess
        isPurchased = cachedStoreEntitlement || cachedAdminAccess
#else
        isPurchased = cachedStoreEntitlement
#endif
        if observesTransactionUpdates {
            transactionListenerTask = listenForTransactions()
        }
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
                switch verification {
                case .verified(let transaction):
                    applyVerified(transaction)
                    await transaction.finish()
                case .unverified(let transaction, _):
                    // A failed signature check must never grant the entitlement,
                    // but the transaction still has to be finished. Leaving it in
                    // the queue makes StoreKit re-deliver it on every launch,
                    // which used to re-raise this banner forever.
                    await transaction.finish()
                    noteUnverifiedTransaction(
                        id: transaction.id,
                        message: Self.unverifiedPurchaseMessage
                    )
                    preserveCachedEntitlement()
                }
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
    ///
    /// Internal rather than private only so those rules can be asserted
    /// directly against an injected `EntitlementSource`.
    @discardableResult
    func refreshEntitlement(allowDefinitiveMissing: Bool) async -> Bool {
        entitlementStatus = .checking

        for record in await entitlementSource.currentEntitlements(for: Self.productID) {
            guard record.productID == Self.productID else { continue }
            switch record {
            case .verified(_, let revocationDate):
                if revocationDate == nil {
                    applyEntitlement(revocationDate: nil, postSuccessNotification: false)
                    return true
                }
                setPurchased(false, status: .notPurchased)
                return false
            case .unverified:
                preserveCachedEntitlement()
                return false
            }
        }

        if let latest = await entitlementSource.latestTransaction(for: Self.productID) {
            switch latest {
            case .verified(_, let revocationDate):
                if revocationDate == nil {
                    applyEntitlement(revocationDate: nil, postSuccessNotification: false)
                    return true
                }
                setPurchased(false, status: .notPurchased)
                return false
            case .unverified:
                preserveCachedEntitlement()
                return false
            }
        }

        if allowDefinitiveMissing, !isPurchased {
            setPurchased(false, status: .notPurchased)
        } else {
            // An empty entitlement set is not proof of "never purchased".
            // `AppStore.sync()` routinely succeeds while entitlements are
            // still propagating (fresh Apple Account sign-in, Family Sharing
            // re-evaluation), and this device's cached entitlement could only
            // have been written by a previously verified transaction. Revoking
            // a paying customer's offline access is far worse than leaving a
            // stale flag, so only a verified revocation may downgrade.
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
                    // Finish first: an unverified transaction that is never
                    // finished is re-delivered on every launch forever.
                    await transaction.finish()
                    if transaction.productID == Self.productID {
                        self.noteUnverifiedTransaction(
                            id: transaction.id,
                            message: Self.unverifiedUpdateMessage
                        )
                        self.preserveCachedEntitlement()
                    }
                }
            }
        }
    }

    /// Surfaces a verification failure at most once per transaction so a
    /// repeated delivery cannot leave a permanent banner on the paywall.
    private func noteUnverifiedTransaction(id: UInt64, message: String) {
        guard reportedUnverifiedTransactionIDs.insert(id).inserted else { return }
        errorMessage = message
    }

    /// Drops a verification warning once access has been confirmed again.
    /// Only the two verification strings are cleared, so a genuine load or
    /// restore failure stays visible.
    private func clearStaleVerificationWarning() {
        if errorMessage == Self.unverifiedUpdateMessage
            || errorMessage == Self.unverifiedPurchaseMessage {
            errorMessage = nil
        }
    }

    private func applyVerified(
        _ transaction: StoreKit.Transaction,
        postSuccessNotification: Bool = true
    ) {
        guard transaction.productID == Self.productID else { return }
        applyEntitlement(
            revocationDate: transaction.revocationDate,
            postSuccessNotification: postSuccessNotification
        )
    }

    private func applyEntitlement(
        revocationDate: Date?,
        postSuccessNotification: Bool
    ) {
        statusMessage = nil

        if revocationDate != nil {
            setPurchased(false, status: .notPurchased)
            return
        }

        setPurchased(true, status: .entitled)
        clearStaleVerificationWarning()
        if postSuccessNotification {
            DuckHaptics.success()
            NotificationCenter.default.post(name: .purchaseDidSucceed, object: nil)
        }
    }

    private func preserveCachedEntitlement() {
        entitlementStatus = hasStoreEntitlement ? .usingCachedEntitlement : .unknown
#if DEBUG
        if isAdminAccessEnabled {
            entitlementStatus = .adminUnlocked
        }
#endif
    }

    private func setPurchased(_ purchased: Bool, status: EntitlementStatus) {
        hasStoreEntitlement = purchased
        defaults.set(purchased, forKey: Self.purchaseCacheKey)
        refreshEffectiveAccess()
#if DEBUG
        entitlementStatus = isAdminAccessEnabled ? .adminUnlocked : status
#else
        entitlementStatus = status
#endif
    }

#if DEBUG
    // MARK: - Developer admin access

    /// Enables every paid feature in development builds without mutating the
    /// real StoreKit entitlement cache. This API and its persisted override are
    /// compiled out of Archive/Release builds.
    func setAdminAccessEnabled(_ enabled: Bool) {
        isAdminAccessEnabled = enabled
        defaults.set(enabled, forKey: Self.adminAccessKey)
        refreshEffectiveAccess()
        entitlementStatus = enabled
            ? .adminUnlocked
            : (hasStoreEntitlement ? .entitled : .notPurchased)
        statusMessage = enabled
            ? "Developer admin access enabled."
            : "Developer admin access disabled."
    }
#endif

    private func refreshEffectiveAccess() {
#if DEBUG
        isPurchased = hasStoreEntitlement || isAdminAccessEnabled
#else
        isPurchased = hasStoreEntitlement
#endif
    }
}
