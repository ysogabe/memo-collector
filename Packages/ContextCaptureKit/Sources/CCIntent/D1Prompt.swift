import CCCore
import Foundation

/// d1 の質問（`prompt.py` の `Choice` / `Noul`）。`Score` は製品で使わないので持たない。
public enum D1Question: Sendable, Equatable {
    /// 選択肢。`options` は (ラベル, 説明) の順序つき列。説明が nil ならラベルの `_` を空白にしたものを使う。
    case choice(instructions: String, options: [D1Option])
    /// yes / no。
    case noul(instructions: String)
}

public struct D1Option: Sendable, Equatable {
    public var label: String
    public var description: String?
    public init(label: String, description: String?) {
        self.label = label
        self.description = description
    }
}

/// 製品で使う質問（`poc/scripts/common.py` の `INTENT_Q_EN` / `DEADLINE_Q` と同一文字列）。
public enum D1Questions {
    /// 意図 5 択。選択肢の順序は `Intent.allCases` と同じ（todo, research, code, note, schedule）。
    public static let intent = D1Question.choice(
        instructions: "The user pressed a hotkey while looking at their screen and spoke this short voice note. "
            + "What kind of follow-up does the note ask for?",
        options: [
            D1Option(label: "todo", description: "A personal to-do the user will do themselves (buy, reply, check, update, read)"),
            D1Option(label: "research", description: "Ask an AI agent to investigate, look up, survey or compare information"),
            D1Option(label: "code", description: "Ask a coding agent to write, fix, refactor or test source code"),
            D1Option(label: "note", description: "Just a remark or reference to remember; no action requested"),
            D1Option(label: "schedule", description: "An appointment or meeting at a specific date and time"),
        ]
    )

    /// `intent` の選択肢ラベルに対応する `Intent`（同じ順序）。
    public static let intentLabels: [Intent] = [.todo, .research, .code, .note, .schedule]

    /// 日時言及（yes / no）。
    public static let deadline = D1Question.noul(
        instructions: "Does the note mention a date, day of the week or time (a deadline or an appointment)?"
    )
}

/// d1 のプロンプト組み立てと readout（`prompt.py` の `render` / `readout_ids` / `readout` の移植）。
/// 状態は注釈テキスト（文字列）、スタイルは d1 既定の `json_only`、system なし、lead なし、`option_style = "desc"`。
public struct D1Prompt: Sendable {
    public static let bos = "<|startoftext|>"
    public static let imStart = "<|im_start|>"
    public static let imEnd = "<|im_end|>"
    static let yesForms = ["yes", "Yes", "YES"]
    static let noForms = ["no", "No", "NO"]

    public let tokenizer: D1Tokenizer

    public init(tokenizer: D1Tokenizer) {
        self.tokenizer = tokenizer
    }

    /// `option_codes`: ラベルがすべて 1 文字の英字ならそのまま、26 個以下なら A..Z、それ以上は 00..。
    public static func optionCodes(_ labels: [String]) -> [String] {
        let labs = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !labs.isEmpty, labs.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) { return labs }
        if labs.count <= 26 { return labs.indices.map { String(UnicodeScalar(UInt8(65 + $0))) } }
        return labs.indices.map { String(format: "%02d", $0) }
    }

    /// `aliases`: 各ラベルに重複しない 1 トークンのコードを割り当てる（[(コード, ID)]）。
    /// d1 の _FALLBACK_POOL は 5 択では使われない（A〜E がそれぞれ 1 トークン）。使うことになったら throw する。
    public func aliases(_ labels: [String]) throws -> [(code: String, id: Int)] {
        var used = Set<Int>()
        var out: [(String, Int)] = []
        for code in Self.optionCodes(labels) {
            let enc = tokenizer.encode(code)
            guard enc.count == 1, !used.contains(enc[0]) else {
                throw D1TokenizerError.noSingleTokenAlias(code)
            }
            out.append((code, enc[0]))
            used.insert(enc[0])
        }
        return out
    }

    /// 1 トークンになる表記だけを重複なく拾う（`_ids`）。
    func singleTokenIds(_ texts: [String]) -> [Int] {
        var out: [Int] = []
        var seen = Set<Int>()
        for t in texts {
            let enc = tokenizer.encode(t)
            if enc.count == 1, !seen.contains(enc[0]) {
                out.append(enc[0])
                seen.insert(enc[0])
            }
        }
        return out
    }

    /// `readout_ids`: 選択肢ごとの ID 群（max-pool する）。noul は [yes 群, no 群]。
    public func readoutIds(_ q: D1Question) throws -> [[Int]] {
        switch q {
        case .noul:
            let yes = singleTokenIds(Self.yesForms), no = singleTokenIds(Self.noForms)
            guard !yes.isEmpty, !no.isEmpty else { throw D1TokenizerError.noSingleTokenAlias("yes/no") }
            return [yes, no]
        case let .choice(_, options):
            return try aliases(options.map(\.label)).map { code, tid in
                [tid] + singleTokenIds([" \(code)"]).filter { $0 != tid }
            }
        }
    }

    /// `question_block`。
    public func questionBlock(_ q: D1Question) throws -> String {
        switch q {
        case let .noul(instructions):
            return "\(instructions)\n\nReply with yes or no only."
        case let .choice(instructions, options):
            let codes = try aliases(options.map(\.label))
            let lines = zip(codes, options).map { code, opt in
                "\(code.code) \(opt.description ?? opt.label.replacingOccurrences(of: "_", with: " "))"
            }.joined(separator: "\n")
            return "\(instructions)\n\nOptions:\n\(lines)\n\nReply with the option code only."
        }
    }

    /// `render(tokenizer, state, q, bos=BOS)`。状態（注釈テキスト）は加工せずそのまま埋め込む（d1 と同じ）。
    public func render(state: String, question: D1Question) throws -> String {
        let prefix = "\(Self.bos)\(Self.imStart)user\n\(state)\n\n\nQUESTION:\n"
        return prefix + (try questionBlock(question)) + "\(Self.imEnd)\n\(Self.imStart)assistant\n"
    }

    /// プロンプトの ID 列（BOS は文字列に含まれているので足さない）。
    public func encode(state: String, question: D1Question) throws -> [Int] {
        tokenizer.encode(try render(state: state, question: question))
    }

    /// `readout`: 各選択肢の最大 logit を取り、その数個だけで softmax する（全語彙の正規化は打ち消し合う）。
    /// `logit(id)` は最終位置の logit（または log 確率）。
    public static func readout(groups: [[Int]], logit: (Int) -> Double) -> [Double] {
        let scores = groups.map { g in g.map(logit).max()! }
        let m = scores.max()!
        let e = scores.map { Foundation.exp($0 - m) }
        let z = e.reduce(0, +)
        return e.map { $0 / z }
    }
}
