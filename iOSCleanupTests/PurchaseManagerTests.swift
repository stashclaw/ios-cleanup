import XCTest
@testable import iOSCleanup

/// Deterministic stand-in for `StoreKit.Transaction.currentEntitlements` and
/// `StoreKit.Transaction.latest(for:)`.
private struct StubEntitlementSource: EntitlementSource {
    var entitlements: [EntitlementRecord] = []
    var latest: EntitlementRecord?

    func currentEntitlements(for productID: String) async -> [EntitlementRecord] {
        entitlements
    }

    func latestTransaction(for productID: String) async -> EntitlementRecord? {
        latest
    }
}

@MainActor
final class PurchaseManagerTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "PurchaseManagerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "Could not create isolated defaults"
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeManager(
        cachedEntitlement: Bool = false,
        source: StubEntitlementSource = StubEntitlementSource()
    ) -> PurchaseManager {
        defaults.set(cachedEntitlement, forKey: "isPurchased")
        // The live `Transaction.updates` listener is disabled so entitlement
        // state can only change through the injected source.
        return PurchaseManager(
            defaults: defaults,
            entitlementSource: source,
            observesTransactionUpdates: false
        )
    }

    // MARK: - Rule (a): verified, not revoked -> purchased

    func testVerifiedNonRevokedEntitlementUnlocksAndCaches() async {
        let manager = makeManager(
            cachedEntitlement: false,
            source: StubEntitlementSource(
                entitlements: [
                    .verified(productID: PurchaseManager.productID, revocationDate: nil)
                ]
            )
        )
        XCTAssertFalse(manager.isPurchased)

        await manager.updatePurchaseStatus()

        XCTAssertTrue(manager.isPurchased)
        XCTAssertEqual(manager.entitlementStatus, .entitled)
        XCTAssertTrue(defaults.bool(forKey: "isPurchased"))
    }

    func testEntitlementForAnotherProductIsIgnoredAndFallsThroughToLatest() async {
        let manager = makeManager(
            cachedEntitlement: false,
            source: StubEntitlementSource(
                entitlements: [.verified(productID: "com.photoduck.app.other", revocationDate: nil)],
                latest: .verified(productID: PurchaseManager.productID, revocationDate: nil)
            )
        )

        await manager.updatePurchaseStatus()

        XCTAssertTrue(manager.isPurchased)
        XCTAssertEqual(manager.entitlementStatus, .entitled)
    }

    // MARK: - Rule (b): verified revocation -> downgrade

    func testVerifiedRevocationDowngradesAndClearsCache() async {
        let manager = makeManager(
            cachedEntitlement: true,
            source: StubEntitlementSource(
                entitlements: [
                    .verified(productID: PurchaseManager.productID, revocationDate: Date())
                ]
            )
        )
        XCTAssertTrue(manager.isPurchased, "Cached entitlement should load at init")

        await manager.updatePurchaseStatus()

        XCTAssertFalse(manager.isPurchased)
        XCTAssertEqual(manager.entitlementStatus, .notPurchased)
        XCTAssertFalse(defaults.bool(forKey: "isPurchased"))
    }

    func testVerifiedRevocationFromLatestTransactionAlsoDowngrades() async {
        let manager = makeManager(
            cachedEntitlement: true,
            source: StubEntitlementSource(
                entitlements: [],
                latest: .verified(productID: PurchaseManager.productID, revocationDate: Date())
            )
        )

        await manager.updatePurchaseStatus()

        XCTAssertFalse(manager.isPurchased)
        XCTAssertEqual(manager.entitlementStatus, .notPurchased)
        XCTAssertFalse(defaults.bool(forKey: "isPurchased"))
    }

    // MARK: - Rule (c): unverified -> cached access preserved

    func testUnverifiedEntitlementPreservesCachedAccess() async {
        let manager = makeManager(
            cachedEntitlement: true,
            source: StubEntitlementSource(
                entitlements: [.unverified(productID: PurchaseManager.productID)]
            )
        )

        await manager.updatePurchaseStatus()

        XCTAssertTrue(manager.isPurchased, "An unverified record is not a verified revocation")
        XCTAssertEqual(manager.entitlementStatus, .usingCachedEntitlement)
        XCTAssertTrue(defaults.bool(forKey: "isPurchased"))
    }

    func testUnverifiedEntitlementDoesNotGrantAccessToNonPurchaser() async {
        let manager = makeManager(
            cachedEntitlement: false,
            source: StubEntitlementSource(
                entitlements: [.unverified(productID: PurchaseManager.productID)]
            )
        )

        await manager.updatePurchaseStatus()

        XCTAssertFalse(manager.isPurchased)
        XCTAssertEqual(manager.entitlementStatus, .unknown)
        XCTAssertFalse(defaults.bool(forKey: "isPurchased"))
    }

    // MARK: - Rule (d): empty result on explicit restore -> cached access preserved

    func testEmptyResultOnExplicitRestorePreservesCachedAccess() async {
        let manager = makeManager(cachedEntitlement: true, source: StubEntitlementSource())

        // The `allowDefinitiveMissing: true` path is what `restore()` runs after
        // a successful `AppStore.sync()`.
        let foundPurchase = await manager.refreshEntitlement(allowDefinitiveMissing: true)

        XCTAssertFalse(foundPurchase)
        XCTAssertTrue(manager.isPurchased, "A successful restore with no records must not revoke")
        XCTAssertEqual(manager.entitlementStatus, .usingCachedEntitlement)
        XCTAssertTrue(defaults.bool(forKey: "isPurchased"))
    }

    func testEmptyResultOnExplicitRestoreForNonPurchaserResolvesToNotPurchased() async {
        let manager = makeManager(cachedEntitlement: false, source: StubEntitlementSource())

        let foundPurchase = await manager.refreshEntitlement(allowDefinitiveMissing: true)

        XCTAssertFalse(foundPurchase)
        XCTAssertFalse(manager.isPurchased)
        XCTAssertEqual(manager.entitlementStatus, .notPurchased)
    }

    // MARK: - Offline / inconclusive launch check

    func testEmptyResultOnLaunchCheckPreservesCachedAccess() async {
        let manager = makeManager(cachedEntitlement: true, source: StubEntitlementSource())

        await manager.updatePurchaseStatus()

        XCTAssertTrue(manager.isPurchased, "An inconclusive launch check must never revoke")
        XCTAssertEqual(manager.entitlementStatus, .usingCachedEntitlement)
        XCTAssertTrue(defaults.bool(forKey: "isPurchased"))
    }

    func testEmptyResultOnLaunchCheckLeavesNonPurchaserUnknown() async {
        let manager = makeManager(cachedEntitlement: false, source: StubEntitlementSource())

        await manager.updatePurchaseStatus()

        XCTAssertFalse(manager.isPurchased)
        XCTAssertEqual(
            manager.entitlementStatus,
            .unknown,
            "Without cached access an inconclusive launch check stays unknown, not .notPurchased"
        )
        XCTAssertFalse(defaults.bool(forKey: "isPurchased"))
    }

    func testRepeatedInconclusiveChecksNeverDowngradeAPurchaser() async {
        let manager = makeManager(cachedEntitlement: true, source: StubEntitlementSource())

        for _ in 0..<5 {
            await manager.updatePurchaseStatus()
        }

        XCTAssertTrue(manager.isPurchased)
        XCTAssertTrue(defaults.bool(forKey: "isPurchased"))
    }

    func testCachedEntitlementSurvivesRelaunch() async {
        let manager = makeManager(
            cachedEntitlement: false,
            source: StubEntitlementSource(
                entitlements: [
                    .verified(productID: PurchaseManager.productID, revocationDate: nil)
                ]
            )
        )
        await manager.updatePurchaseStatus()
        XCTAssertTrue(manager.isPurchased)

        // Relaunch offline: no entitlement records available at all.
        let relaunched = PurchaseManager(
            defaults: defaults,
            entitlementSource: StubEntitlementSource(),
            observesTransactionUpdates: false
        )
        XCTAssertTrue(relaunched.isPurchased)

        await relaunched.updatePurchaseStatus()

        XCTAssertTrue(relaunched.isPurchased)
        XCTAssertEqual(relaunched.entitlementStatus, .usingCachedEntitlement)
    }

#if DEBUG
    func testAdminAccessUnlocksAllPaidFeatureGatesAndPersistsSeparately() {
        let manager = makeManager()
        XCTAssertFalse(manager.isPurchased)
        XCTAssertFalse(manager.isAdminAccessEnabled)

        manager.setAdminAccessEnabled(true)

        XCTAssertTrue(manager.isPurchased)
        XCTAssertTrue(manager.isAdminAccessEnabled)
        XCTAssertEqual(manager.entitlementStatus, .adminUnlocked)
        XCTAssertFalse(defaults.bool(forKey: "isPurchased"))

        let relaunchedManager = PurchaseManager(
            defaults: defaults,
            entitlementSource: StubEntitlementSource(),
            observesTransactionUpdates: false
        )
        XCTAssertTrue(relaunchedManager.isPurchased)
        XCTAssertTrue(relaunchedManager.isAdminAccessEnabled)

        relaunchedManager.setAdminAccessEnabled(false)

        XCTAssertFalse(relaunchedManager.isPurchased)
        XCTAssertFalse(relaunchedManager.isAdminAccessEnabled)
        XCTAssertFalse(defaults.bool(forKey: "isPurchased"))
    }

    func testAdminAccessOverridesInconclusiveEntitlementStatus() async {
        let manager = makeManager(cachedEntitlement: false, source: StubEntitlementSource())
        manager.setAdminAccessEnabled(true)

        await manager.updatePurchaseStatus()

        XCTAssertTrue(manager.isPurchased)
        XCTAssertEqual(manager.entitlementStatus, .adminUnlocked)
        XCTAssertFalse(defaults.bool(forKey: "isPurchased"))
    }
#endif
}
