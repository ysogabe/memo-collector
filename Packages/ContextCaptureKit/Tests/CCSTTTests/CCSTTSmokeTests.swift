import XCTest
@testable import CCSTT

final class CCSTTSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(CCSTTModule.name, "CCSTT")
    }
}
