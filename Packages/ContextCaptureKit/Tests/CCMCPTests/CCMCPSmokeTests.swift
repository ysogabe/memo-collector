import XCTest
@testable import CCMCP

final class CCMCPSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(CCMCPModule.name, "CCMCP")
    }
}
