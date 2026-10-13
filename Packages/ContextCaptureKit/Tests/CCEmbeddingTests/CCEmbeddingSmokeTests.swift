import XCTest
@testable import CCEmbedding

final class CCEmbeddingSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(CCEmbeddingModule.name, "CCEmbedding")
    }
}
