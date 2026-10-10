import CCCore
import Foundation
import XCTest
@testable import CCIntent

/// モデル・トークナイザが無くても回るプロンプト / readout の単体テスト。
final class D1PromptTests: XCTestCase {
    func testOptionCodes() {
        XCTAssertEqual(D1Prompt.optionCodes(["todo", "research", "code", "note", "schedule"]), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(D1Prompt.optionCodes(["x", "Y"]), ["x", "Y"])
        XCTAssertEqual(D1Prompt.optionCodes((0..<27).map { "l\($0)" }).prefix(3), ["00", "01", "02"])
    }

    func testReadoutMaxPoolsThenSoftmaxesOverOptionTokensOnly() {
        let logits: [Int: Double] = [1: 2.0, 2: 5.0, 3: 1.0, 4: 1.0]
        let p = D1Prompt.readout(groups: [[1, 2], [3, 4]]) { logits[$0]! }
        let e = exp(1.0) / (exp(1.0) + exp(-3.0))
        XCTAssertEqual(p[0], e, accuracy: 1e-12)
        XCTAssertEqual(p[0] + p[1], 1, accuracy: 1e-12)
        // 定数を足しても変わらない（全語彙の正規化は打ち消し合う）
        let q = D1Prompt.readout(groups: [[1, 2], [3, 4]]) { logits[$0]! - 42 }
        XCTAssertEqual(p, q)
    }

    func testIntentLabelsFollowIntentAllCases() {
        XCTAssertEqual(D1Questions.intentLabels, Intent.allCases)
        guard case let .choice(_, options) = D1Questions.intent else { return XCTFail() }
        XCTAssertEqual(options.map(\.label), Intent.allCases.map(\.rawValue))
    }

    func testRenderMatchesD1Template() throws {
        let tok = try D1TestSupport.tokenizer()
        let p = D1Prompt(tokenizer: tok)
        XCTAssertEqual(
            try p.render(state: "メモ", question: D1Questions.deadline),
            "<|startoftext|><|im_start|>user\nメモ\n\n\nQUESTION:\n"
                + "Does the note mention a date, day of the week or time (a deadline or an appointment)?"
                + "\n\nReply with yes or no only.<|im_end|>\n<|im_start|>assistant\n")
    }
}
