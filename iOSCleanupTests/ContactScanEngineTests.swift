import XCTest
import Contacts
@testable import iOSCleanup

final class ContactScanEngineTests: XCTestCase {

    // MARK: - PhoneNormalizer

    func testPhoneNormalizationFull() {
        XCTAssertEqual(PhoneNormalizer.normalize("+1 (555) 867-5309"), "15558675309")
    }

    func testPhoneNormalizationTenDigit() {
        XCTAssertEqual(PhoneNormalizer.normalize("555-867-5309"), "15558675309")
    }

    func testPhoneNormalizationTooShort() {
        XCTAssertNil(PhoneNormalizer.normalize("1234"))
    }

    func testPhoneNormalizationAlreadyE164() {
        XCTAssertEqual(PhoneNormalizer.normalize("15558675309"), "15558675309")
    }

    // MARK: - NameMatcher

    func testFuzzyNameOneCharDiff() {
        XCTAssertTrue(NameMatcher.isFuzzyMatch("John Smith", "Jon Smith"))
    }

    func testFuzzyNameReversed() {
        XCTAssertTrue(NameMatcher.isFuzzyMatch("John Smith", "Smith John"))
    }

    func testFuzzyNameNoMatch() {
        XCTAssertFalse(NameMatcher.isFuzzyMatch("John Smith", "Jane Doe"))
    }

    func testFuzzyNameExactMatch() {
        XCTAssertTrue(NameMatcher.isFuzzyMatch("Alice Johnson", "Alice Johnson"))
    }

    func testLevenshteinDistance() {
        XCTAssertEqual(NameMatcher.distance("John Smith", "Jon Smith"), 1)
        XCTAssertEqual(NameMatcher.distance("John Smith", "John Smith"), 0)
    }

    // MARK: - ContactMatch in-memory

    func testInMemoryContactMatchConfidence() {
        let contactA = CNMutableContact()
        contactA.givenName = "John"
        contactA.familyName = "Smith"
        contactA.phoneNumbers = [CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: "+1 (555) 867-5309")
        )]

        let contactB = CNMutableContact()
        contactB.givenName = "John"
        contactB.familyName = "Smith"
        contactB.phoneNumbers = [CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: "555-867-5309")
        )]

        // Simulate phone index matching
        let normalA = PhoneNormalizer.normalize("+1 (555) 867-5309")
        let normalB = PhoneNormalizer.normalize("555-867-5309")
        XCTAssertEqual(normalA, normalB, "Both numbers should normalize to the same value")

        // Verify name distance
        let nameA = "John Smith"
        let nameB = "John Smith"
        XCTAssertEqual(NameMatcher.distance(nameA, nameB), 0)
        XCTAssertTrue(NameMatcher.isFuzzyMatch(nameA, nameB))
    }
}
