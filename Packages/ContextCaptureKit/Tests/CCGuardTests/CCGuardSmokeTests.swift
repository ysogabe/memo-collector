import XCTest
@testable import CCGuard

final class CCGuardSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(CCGuardModule.name, "CCGuard")
    }
}
