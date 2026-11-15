@testable import CompanionCore
import XCTest

final class HandleNormalizerTests: XCTestCase {
    func test_vectors() {
        XCTAssertEqual(HandleNormalizer.normalize(" +1 (555) 555-0100 "), "+15555550100")
        XCTAssertEqual(HandleNormalizer.normalize("Test@Example.COM"), "test@example.com")
        XCTAssertEqual(HandleNormalizer.normalize("555.555.0100"), "5555550100")
        XCTAssertEqual(HandleNormalizer.normalize("abc-123"), "abc-123")
        XCTAssertEqual(HandleNormalizer.normalize("\n+44 20 7946 0000\t"), "+442079460000")
        XCTAssertEqual(HandleNormalizer.normalize(""), "")
    }

    /// The value the fork computes today for the same input (HomeChat stores it and compares later ones).
    func test_fingerprintUnchanged() {
        XCTAssertEqual(CompanionFingerprint.of(handles: ["+1 555 555 0100", "test@example.com"]), "0e6c649db09c1e53ccacf5d18f9ffb58f0ff94b9da3703b3837192348806a68b")
    }
}
