import MLX
import XCTest

/// MLX が Metal（.metallib）付きで実行できることの確認。
/// SwiftPM のコマンドライン（`swift test`）では metallib が作られず失敗しうるので、check.sh はこれが通るコマンドを使う。
final class MLXMetalTests: XCTestCase {
    func testArraySumOnGPU() {
        let result = Device.withDefaultDevice(.gpu) {
            XCTAssertEqual(Device.defaultDevice().deviceType, .gpu)
            return MLXArray([1, 2, 3] as [Int32]).sum()
        }
        eval(result)
        XCTAssertEqual(result.item(Int32.self), 6)
    }
}
