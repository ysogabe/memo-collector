import Foundation
import XCTest
@testable import CCIntent

/// D1Tokenizer / D1Prompt が HF（Rust `tokenizers` + d1 の `prompt.py`）と同じ文字列・同じ ID 列を作ること。
/// tokenizer.json が無い環境では skip（モデル本体は不要）。
final class D1TokenizerTests: XCTestCase {
    /// 参照 52 件 × 2 質問 = 104 件: プロンプト文字列・ID 列・readout 群がすべて一致する（Go 条件）。
    func testReferencePromptsMatchHF104of104() throws {
        let tok = try D1TestSupport.tokenizer()
        let ref = try D1TestSupport.reference()
        let prompt = D1Prompt(tokenizer: tok)
        var checked = 0, mismatches: [String] = []
        for row in ref.rows {
            for (name, q) in row.q {
                let question = D1TestSupport.question(name)
                let rendered = try prompt.render(state: row.text, question: question)
                XCTAssertEqual(rendered, q.prompt, "prompt \(row.id)/\(name)")
                let ids = tok.encode(rendered)
                if ids != q.ids { mismatches.append("\(row.id)/\(name)") }
                XCTAssertEqual(try prompt.readoutIds(question), q.groups, "groups \(row.id)/\(name)")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 104)
        XCTAssertEqual(mismatches, [], "token mismatch \(mismatches.count)/\(checked)")
    }

    /// 参照に無い入力（句読点終わり・絵文字・英数字混在・改行・空に近い文字列・特殊トークン文字列など）。
    /// 生テキスト単体と、それを状態にしたプロンプト全文（2 質問）の両方で HF と一致する。
    func testFixtureCasesMatchHF() throws {
        let tok = try D1TestSupport.tokenizer()
        let fx = try D1TestSupport.cases()
        let prompt = D1Prompt(tokenizer: tok)
        XCTAssertGreaterThanOrEqual(fx.cases.count, 90)
        var bad: [String] = []
        for c in fx.cases {
            if tok.encode(c.text) != c.ids { bad.append("text \(c.text.debugDescription)") }
            for (name, p) in c.prompts {
                let rendered = try prompt.render(state: c.text, question: D1TestSupport.question(name))
                XCTAssertEqual(rendered, p.prompt, "prompt \(c.text.debugDescription)/\(name)")
                if tok.encode(rendered) != p.ids { bad.append("prompt \(name) \(c.text.debugDescription)") }
            }
        }
        XCTAssertEqual(bad, [], "\(bad.count) mismatches")
        for (name, groups) in fx.readout_ids {
            XCTAssertEqual(try prompt.readoutIds(D1TestSupport.question(name)), groups, name)
        }
    }

    /// テンプレート境界でユーザー文と改行が 1 トークンに融合する（定数 ID の連結では作れない）ことの確認。
    func testUserTextFusesWithTemplateNewlines() throws {
        let tok = try D1TestSupport.tokenizer()
        // "。" + "\n\n\n" は 1 トークン、空の状態では "user\n" の改行と "\n\n\n" が 1 トークン（"\n\n\n\n"）になる
        XCTAssertEqual(tok.preTokenize("調べる。\n\n\nQUESTION:\n"), ["調べる", "。\n\n\n", "QUESTION", ":\n"])
        XCTAssertEqual(tok.encode("\n\n\n"), [7])
        XCTAssertEqual(tok.encode("\n\n"), [8])
    }

    /// 根本原因（swift-transformers 1.3.4 の不一致）: Split 前分割は `String.range(of:options:.regularExpression, range:)`
    /// で 1 個ずつ探している（String+PreTokenization.swift）。macOS 27 の Foundation ではこの経路が Swift Regex の
    /// 書記素クラスタ単位の意味論で照合し、文字クラス `[\r\n]` が「CRLF の 1 書記素」だけに一致して単独の LF に
    /// 一致しない（`[\n]` や `\n` は一致する）。結果 `\s*[\r\n]` が効かず、後ろの `\s+(?!\S)` が LF 2 個を取り、
    /// 残りの LF は `[^\r\n\p{L}\p{N}]?\p{L}+` に後続の英字ごと取られる（LF + "Q"）。BPE の ignore_merges は無関係
    /// （HF でも ignore_merges=false で同じ列になる）。D1Tokenizer は NSRegularExpression（ICU、UTF-16 単位）で照合する。
    /// ここでは D1Tokenizer の前分割が HF と同じことを確かめ、Foundation 側の挙動は記録として出力する（OS が直れば変わるので assert しない）。
    func testPreTokenizeUsesCodePointRegexNotGraphemeRegex() throws {
        let tok = try D1TestSupport.tokenizer()
        XCTAssertEqual(tok.preTokenize("調べる\n\n\nQUESTION:\ntime\n\nReply"),
                       ["調べる", "\n\n\n", "QUESTION", ":\n", "time", "\n\n", "Reply"])
        XCTAssertEqual(tok.preTokenize("CRLF\r\n改行"), ["CRLF", "\r\n", "改行"])
        let quirk = "x\nx".range(of: #"[\r\n]"#, options: .regularExpression) == nil
        print("D1TOKENIZER Foundation String.range(of:.regularExpression) [\\r\\n] misses a lone LF: \(quirk)")
    }
}
