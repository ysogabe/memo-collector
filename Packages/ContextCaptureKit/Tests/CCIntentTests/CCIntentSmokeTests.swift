import XCTest
@testable import CCIntent

final class CCIntentSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(CCIntentModule.name, "CCIntent")
    }
}
