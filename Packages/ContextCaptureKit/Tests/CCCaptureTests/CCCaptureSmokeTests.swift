import XCTest
@testable import CCCapture

final class CCCaptureSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(CCCaptureModule.name, "CCCapture")
    }
}
