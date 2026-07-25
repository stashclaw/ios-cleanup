import XCTest
@testable import iOSCleanup

@MainActor
final class PurchaseManagerTests: XCTestCase {

#if DEBUG
    func testAdminAccessUnlocksAllPaidFeatureGatesAndPersistsSeparately() {
        let suiteName = "PurchaseManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = PurchaseManager(defaults: defaults)
        XCTAssertFalse(manager.isPurchased)
        XCTAssertFalse(manager.isAdminAccessEnabled)

        manager.setAdminAccessEnabled(true)

        XCTAssertTrue(manager.isPurchased)
        XCTAssertTrue(manager.isAdminAccessEnabled)
        XCTAssertEqual(manager.entitlementStatus, .adminUnlocked)
        XCTAssertFalse(defaults.bool(forKey: "isPurchased"))

        let relaunchedManager = PurchaseManager(defaults: defaults)
        XCTAssertTrue(relaunchedManager.isPurchased)
        XCTAssertTrue(relaunchedManager.isAdminAccessEnabled)

        relaunchedManager.setAdminAccessEnabled(false)

        XCTAssertFalse(relaunchedManager.isPurchased)
        XCTAssertFalse(relaunchedManager.isAdminAccessEnabled)
        XCTAssertFalse(defaults.bool(forKey: "isPurchased"))
    }
#endif
}
