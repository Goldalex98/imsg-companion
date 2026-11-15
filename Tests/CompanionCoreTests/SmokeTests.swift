@testable import CompanionCore
import XCTest

final class SmokeTests: XCTestCase {
  func test_imsgCoreVersionMatchesPin() {
    XCTAssertEqual(CompanionCore.imsgCoreVersion, "0.21.0")
  }
}
