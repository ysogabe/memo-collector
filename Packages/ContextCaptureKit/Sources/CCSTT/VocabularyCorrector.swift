import Foundation

/// 認識結果の英字部分を語彙（固有名詞辞書）の綴りへ寄せる後処理。
///
/// Whisper は日本語の発話中の英単語を大文字化したり（"issue" → "ISSUE"）、1〜3 文字崩したり
/// （"Hermes" → "HRMES"、"pytest" → "TYDEST"、"adapter.ts" → "ADFTR.ts"）する。
/// 結果中の英数字の並び（空白・"-"・"." を含む連なり）を取り出し、語彙の各語と大文字小文字・空白・"-" を
/// 無視した編集距離で比べ、十分近ければ語彙の綴りに置き換える。
///
/// - 対象は英字を含む語だけ（かな漢字の語はあいまい一致の誤爆が多いので扱わない）
/// - 4 文字未満の語は完全一致（大文字小文字違い）だけ直す（"PSO" と "TSO" のような 1 文字違いは直さない）
/// - 許す距離は語の長さの 1/3（切り捨て）まで
public struct VocabularyCorrector: Sendable, Equatable {
    public struct Term: Sendable, Equatable {
        /// 置き換え後の綴り（語彙そのまま）。
        public var canonical: String
        /// 比較用の正規化形（小文字、空白・"-" を除く）。
        public var key: String
    }

    public let terms: [Term]
    /// 編集距離の許容率（語の長さに対する比）。
    public var maxDistanceRatio: Double
    /// あいまい一致を許す最短の長さ（正規化形）。
    public var minFuzzyLength: Int

    public init(vocabulary: [String], maxDistanceRatio: Double = 1.0 / 3.0, minFuzzyLength: Int = 4) {
        var seen = Set<String>()
        terms = vocabulary.compactMap { raw in
            let canonical = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard canonical.unicodeScalars.contains(where: Self.isASCIILetter) else { return nil }
            let key = Self.key(canonical)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return Term(canonical: canonical, key: key)
        }
        self.maxDistanceRatio = maxDistanceRatio
        self.minFuzzyLength = minFuzzyLength
    }

    /// 後処理を適用する。語彙が空なら入力をそのまま返す。
    public func apply(to text: String) -> String {
        guard !terms.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for run in Self.asciiRuns(in: text) {
            result += text[cursor..<run.lowerBound]
            result += correctRun(String(text[run]))
            cursor = run.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - 内部

    /// 英数字の連なり 1 つを、語単位（空白区切り）の部分列ごとに最良の語へ置き換える。
    func correctRun(_ run: String) -> String {
        // 空白で語に分け、左から貪欲に「最も長く・最も近い」一致を取る
        let words = run.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            var best: (length: Int, distance: Double, term: Term)?
            for length in stride(from: min(words.count - i, 4), through: 1, by: -1) {
                let candidate = words[i..<(i + length)].joined(separator: " ")
                guard let (term, ratio) = bestTerm(for: candidate) else { continue }
                if best == nil || ratio < best!.distance { best = (length, ratio, term) }
            }
            if let best {
                out.append(best.term.canonical)
                i += best.length
            } else {
                out.append(words[i])
                i += 1
            }
        }
        // 元の連なりの先頭・末尾の空白は asciiRuns が含めないので、語の間を 1 つの空白で戻せば足りる
        return out.joined(separator: " ")
    }

    /// 候補に最も近い語と、その距離比（0 = 一致）。許容外なら nil。
    func bestTerm(for candidate: String) -> (Term, Double)? {
        let key = Self.key(candidate)
        guard !key.isEmpty else { return nil }
        var best: (Term, Double)?
        for term in terms {
            let distance: Int
            if key == term.key {
                distance = 0
            } else {
                guard term.key.count >= minFuzzyLength else { continue }
                let allowed = Int(Double(term.key.count) * maxDistanceRatio)
                guard allowed > 0, abs(key.count - term.key.count) <= allowed else { continue }
                distance = Self.levenshtein(Array(key.unicodeScalars), Array(term.key.unicodeScalars))
                guard distance <= allowed else { continue }
            }
            let ratio = Double(distance) / Double(term.key.count)
            if best == nil || ratio < best!.1 { best = (term, ratio) }
        }
        return best
    }

    static func isASCIILetter(_ s: Unicode.Scalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
    }

    static func isRunScalar(_ s: Unicode.Scalar) -> Bool {
        isASCIILetter(s) || (s >= "0" && s <= "9") || s == "." || s == "-" || s == "_"
    }

    /// 比較キー: 小文字化し、空白と "-" を除く。
    static func key(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { $0 != " " && $0 != "-" }))
    }

    /// 英字を 1 文字以上含む「英数字・. - _ と、それらに挟まれた単独の空白」の連なりの範囲。
    /// 末尾の "." / "-"（文末の句点代わり）は連なりに含めない。
    static func asciiRuns(in text: String) -> [Range<String.Index>] {
        var runs: [Range<String.Index>] = []
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            guard isRunScalar(scalars[i]) else { i = scalars.index(after: i); continue }
            let start = i
            var end = i
            var j = i
            while j < scalars.endIndex {
                if isRunScalar(scalars[j]) {
                    j = scalars.index(after: j)
                    end = j
                } else if scalars[j] == " ", scalars.index(after: j) < scalars.endIndex,
                          isRunScalar(scalars[scalars.index(after: j)]) {
                    j = scalars.index(after: j)
                } else {
                    break
                }
            }
            // 末尾の記号を外す
            while end > start {
                let last = scalars[scalars.index(before: end)]
                if last == "." || last == "-" || last == "_" { end = scalars.index(before: end) } else { break }
            }
            if end > start, scalars[start..<end].contains(where: isASCIILetter) {
                runs.append(start..<end)
            }
            i = j > i ? j : scalars.index(after: i)
        }
        return runs
    }

    static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
