import XCTest
@testable import CCStore

final class CCStoreSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(CCStoreModule.name, "CCStore")
    }
}
