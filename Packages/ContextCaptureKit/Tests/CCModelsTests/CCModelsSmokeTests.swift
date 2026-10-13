import XCTest
@testable import CCModels

final class CCModelsSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(CCModelsModule.name, "CCModels")
    }
}
