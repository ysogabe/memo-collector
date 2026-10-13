import XCTest
@testable import CCSTT

final class VocabularyCorrectorTests: XCTestCase {
    let corrector = VocabularyCorrector(vocabulary: STTTestSupport.pocVocabulary)

    func testFixesCaseAndSmallMisspellings() {
        // WhisperKit の実出力（spikes/runtime/results/stt_whisperkit_plain.json）から
        XCTAssertEqual(corrector.apply(to: "これHRMESのアダプタとして使えそう。"), "これHermesのアダプタとして使えそう。")
        XCTAssertEqual(corrector.apply(to: "このISSUEの修正、CLAUD CODにやらせて、"), "このissueの修正、Claude Codeにやらせて、")
        XCTAssertEqual(corrector.apply(to: "このADFTR.tsの関数、テストを書いておいて、"), "このadapter.tsの関数、テストを書いておいて、")
        XCTAssertEqual(corrector.apply(to: "TYDESTのこのエラー、基地の問題か"), "pytestのこのエラー、基地の問題か")
        XCTAssertEqual(corrector.apply(to: "GITHUBに上げて"), "GitHubに上げて")
    }

    func testKeepsUnrelatedWords() {
        XCTAssertEqual(corrector.apply(to: "USB-Cケーブルを注文する"), "USB-Cケーブルを注文する")
        XCTAssertEqual(corrector.apply(to: "今のAPI以降の話"), "今のAPI以降の話")
        XCTAssertEqual(corrector.apply(to: "TH-UNDERBOLT4、太陽化"), "TH-UNDERBOLT4、太陽化")
        XCTAssertEqual(corrector.apply(to: "ここでNULになる理由"), "ここでNULになる理由")
        XCTAssertEqual(corrector.apply(to: "日本語だけの文。"), "日本語だけの文。")
        // 文末の "." は語に含めない
        XCTAssertEqual(corrector.apply(to: "見て HERMES."), "見て Hermes.")
    }

    func testShortTermsNeedExactMatch() {
        let c = VocabularyCorrector(vocabulary: ["PSO", "gh"])
        XCTAssertEqual(c.apply(to: "TSOのところ"), "TSOのところ")
        XCTAssertEqual(c.apply(to: "psoのところ"), "PSOのところ")
        XCTAssertEqual(c.apply(to: "GHの認証トークン"), "ghの認証トークン")
    }

    func testIgnoresNonLatinTermsAndEmptyVocabulary() {
        XCTAssertTrue(VocabularyCorrector(vocabulary: ["型エラー", " ", ""]).terms.isEmpty)
        XCTAssertEqual(VocabularyCorrector(vocabulary: []).apply(to: "HRMES"), "HRMES")
    }

    func testThunderboltFolding() {
        let c = VocabularyCorrector(vocabulary: ["Thunderbolt 4"])
        XCTAssertEqual(c.apply(to: "このケーブル、TH-UNDERBOLT4、太陽化"), "このケーブル、Thunderbolt 4、太陽化")
    }

    func testLevenshtein() {
        func d(_ a: String, _ b: String) -> Int {
            VocabularyCorrector.levenshtein(Array(a.unicodeScalars), Array(b.unicodeScalars))
        }
        XCTAssertEqual(d("kitten", "sitting"), 3)
        XCTAssertEqual(d("", "abc"), 3)
        XCTAssertEqual(d("adftr.ts", "adapter.ts"), 3)
    }
}
