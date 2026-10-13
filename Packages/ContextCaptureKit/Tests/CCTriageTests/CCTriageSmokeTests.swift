import XCTest
@testable import CCTriage

final class CCTriageSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(CCTriageModule.name, "CCTriage")
    }
}
