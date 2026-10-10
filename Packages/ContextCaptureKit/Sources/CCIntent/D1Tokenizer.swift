import Foundation

/// d1-3B（LFM2 系）の `tokenizer.json` を HF `tokenizers`（Rust 実装）と同じ列に encode する自前トークナイザ。
///
/// なぜ自前か（docs/research/runtime-coreml-mlx.md §4.2 の Go 条件）:
/// swift-transformers 1.3.4 の `AutoTokenizer` は前分割（`Split` の正規表現）を
/// `String.range(of:options:.regularExpression, range:)` で探す。macOS 27 の Foundation ではこの経路が
/// Swift Regex の書記素クラスタ単位の意味論で照合し、文字クラス `[\r\n]` が CRLF の 1 書記素にしか一致せず
/// 単独の LF に一致しない。そのため `\s*[\r\n]` が効かず、改行の連続が HF と違う片に分かれる
/// （LF×3 + "Q" → LF×2 と LF+"Q"、LF×2 + "R" → LF と LF+"R"）。d1 のプロンプトは状態ブロックの後に必ず LF×3 を
/// 含むので全件で列がずれる。BPE の `ignore_merges` は原因ではない（HF で ignore_merges=false にしても同じ列）。
/// ここでは NSRegularExpression（ICU、UTF-16 単位の照合 = HF の Oniguruma と同じ意味論）で前分割する。
/// 確認は `D1TokenizerTests.testPreTokenizeUsesCodePointRegexNotGraphemeRegex`。
///
/// ここでは d1 の `tokenizer.json` が宣言する構成だけを実装し、それ以外の構成は読み込み時に
/// `D1TokenizerError.unsupported` で拒否する（黙って違う列を作らないため）:
/// - normalizer: なし
/// - added_tokens: 文字列どおりに切り出す（左から最長一致。lstrip / rstrip / single_word は false のみ対応）
/// - pre_tokenizer: `Sequence[Split(Regex, Isolated), ByteLevel(add_prefix_space=false, use_regex=false)]`
/// - model: BPE（`ignore_merges` 対応、byte_fallback なし、接頭・接尾辞なし）
public struct D1Tokenizer: Sendable {
    /// 追加トークン（`<|im_start|>` など）。文字列 → ID。
    public let addedTokens: [String: Int]
    /// 語彙のサイズ（追加トークンを除く BPE 語彙）。
    public let vocabularySize: Int

    private let splitRegex: NSRegularExpression
    private let addedByFirstScalar: [Unicode.Scalar: [(scalars: [Unicode.Scalar], id: Int)]]
    private let byteToId: [Int]
    private let bytesToId: [[UInt8]: Int]
    /// (左 ID << 32 | 右 ID) → (rank, 結合後 ID)
    private let merges: [UInt64: (rank: Int, id: Int)]
    private let ignoreMerges: Bool

    /// `tokenizer.json` を読み込む。
    public init(tokenizerJSON url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(tokenizerJSONData: data)
    }

    public init(tokenizerJSONData data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw D1TokenizerError.unsupported("tokenizer.json の最上位がオブジェクトでない")
        }
        if let n = root["normalizer"], !(n is NSNull) {
            throw D1TokenizerError.unsupported("normalizer を持つトークナイザ")
        }

        // ---- pre_tokenizer: Sequence[Split(Regex, Isolated), ByteLevel(no prefix space, no regex)]
        guard let pre = root["pre_tokenizer"] as? [String: Any], pre["type"] as? String == "Sequence",
              let seq = pre["pretokenizers"] as? [[String: Any]], seq.count == 2,
              seq[0]["type"] as? String == "Split", seq[1]["type"] as? String == "ByteLevel"
        else { throw D1TokenizerError.unsupported("pre_tokenizer が Sequence[Split, ByteLevel] でない") }
        let split = seq[0], byteLevel = seq[1]
        guard let pattern = (split["pattern"] as? [String: Any])?["Regex"] as? String,
              split["behavior"] as? String == "Isolated", (split["invert"] as? Bool ?? false) == false
        else { throw D1TokenizerError.unsupported("Split が Regex / Isolated / invert=false でない") }
        guard (byteLevel["add_prefix_space"] as? Bool ?? true) == false,
              (byteLevel["use_regex"] as? Bool ?? true) == false
        else { throw D1TokenizerError.unsupported("ByteLevel が add_prefix_space=false / use_regex=false でない") }
        splitRegex = try NSRegularExpression(pattern: pattern, options: [])

        // ---- model: BPE
        guard let model = root["model"] as? [String: Any], model["type"] as? String == "BPE",
              let vocab = model["vocab"] as? [String: Int], let rawMerges = model["merges"] as? [Any]
        else { throw D1TokenizerError.unsupported("model が BPE でない") }
        for key in ["continuing_subword_prefix", "end_of_word_suffix", "dropout"] {
            if let v = model[key], !(v is NSNull) { throw D1TokenizerError.unsupported("BPE の \(key) が設定されている") }
        }
        if model["byte_fallback"] as? Bool == true { throw D1TokenizerError.unsupported("byte_fallback") }
        ignoreMerges = model["ignore_merges"] as? Bool ?? false

        let decoder = Self.unicodeToByte
        var bytesToId: [[UInt8]: Int] = [:]
        bytesToId.reserveCapacity(vocab.count)
        for (token, id) in vocab {
            guard let bytes = Self.decodeByteLevel(token, decoder) else {
                throw D1TokenizerError.unsupported("byte-level でない語彙: \(token)")
            }
            bytesToId[bytes] = id
        }
        var byteToId = [Int](repeating: -1, count: 256)
        for b in 0..<256 {
            guard let id = bytesToId[[UInt8(b)]] else { throw D1TokenizerError.unsupported("1 バイトの語彙が欠けている: \(b)") }
            byteToId[b] = id
        }
        var merges: [UInt64: (rank: Int, id: Int)] = [:]
        merges.reserveCapacity(rawMerges.count)
        for (rank, m) in rawMerges.enumerated() {
            let pair: [String]
            if let a = m as? [String], a.count == 2 {
                pair = a
            } else if let s = m as? String {
                let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { throw D1TokenizerError.unsupported("merges の形式: \(s)") }
                pair = parts
            } else {
                throw D1TokenizerError.unsupported("merges の形式")
            }
            guard let l = vocab[pair[0]], let r = vocab[pair[1]], let merged = vocab[pair[0] + pair[1]] else { continue }
            let key = UInt64(UInt32(l)) << 32 | UInt64(UInt32(r))
            if merges[key] == nil { merges[key] = (rank, merged) }
        }
        self.bytesToId = bytesToId
        self.byteToId = byteToId
        self.merges = merges
        self.vocabularySize = vocab.count

        // ---- added_tokens
        var added: [String: Int] = [:]
        var byFirst: [Unicode.Scalar: [(scalars: [Unicode.Scalar], id: Int)]] = [:]
        for t in root["added_tokens"] as? [[String: Any]] ?? [] {
            guard let content = t["content"] as? String, let id = t["id"] as? Int, let first = content.unicodeScalars.first else { continue }
            for flag in ["lstrip", "rstrip", "single_word"] where t[flag] as? Bool == true {
                throw D1TokenizerError.unsupported("追加トークン \(content) の \(flag)")
            }
            added[content] = id
            byFirst[first, default: []].append((Array(content.unicodeScalars), id))
        }
        for k in byFirst.keys { byFirst[k]!.sort { $0.scalars.count > $1.scalars.count } }
        addedTokens = added
        addedByFirstScalar = byFirst
    }

    /// テキストを ID 列にする（BOS などは足さない。HF の `encode(text, add_special_tokens=False)` 相当）。
    /// 文中の追加トークン文字列（`<|im_end|>` など）は HF と同じく追加トークンとして切り出す。
    public func encode(_ text: String) -> [Int] {
        var out: [Int] = []
        for segment in splitAddedTokens(text) {
            switch segment {
            case let .added(id): out.append(id)
            case let .text(s): encodeOrdinary(s, into: &out)
            }
        }
        return out
    }

    /// 前分割の結果（テスト・診断用）。各片は元の文字列のまま（byte-level 変換前）。
    public func preTokenize(_ text: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = []
        var last = 0
        for m in splitRegex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { pieces.append(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            if m.range.length > 0 { pieces.append(ns.substring(with: m.range)) }
            last = m.range.location + m.range.length
        }
        if last < ns.length { pieces.append(ns.substring(from: last)) }
        return pieces
    }

    // MARK: - 内部

    private enum Segment { case added(Int), text(String) }

    /// 追加トークンを左から最長一致で切り出す（HF の AddedVocabulary と同じ LeftmostLongest）。
    private func splitAddedTokens(_ text: String) -> [Segment] {
        let scalars = Array(text.unicodeScalars)
        var out: [Segment] = []
        var buf = String.UnicodeScalarView()
        var i = 0
        outer: while i < scalars.count {
            if let cands = addedByFirstScalar[scalars[i]] {
                for c in cands where i + c.scalars.count <= scalars.count
                    && scalars[i ..< i + c.scalars.count].elementsEqual(c.scalars) {
                    if !buf.isEmpty { out.append(.text(String(buf))); buf = String.UnicodeScalarView() }
                    out.append(.added(c.id))
                    i += c.scalars.count
                    continue outer
                }
            }
            buf.append(scalars[i])
            i += 1
        }
        if !buf.isEmpty { out.append(.text(String(buf))) }
        return out
    }

    private func encodeOrdinary(_ text: String, into out: inout [Int]) {
        for piece in preTokenize(text) {
            let bytes = Array(piece.utf8)
            if ignoreMerges, let id = bytesToId[bytes] {
                out.append(id)
                continue
            }
            out.append(contentsOf: bpe(bytes))
        }
    }

    /// rank の小さい結合から 1 つずつ適用する（同 rank は左が先）。片は短いので O(n^2) で足りる。
    private func bpe(_ bytes: [UInt8]) -> [Int] {
        var symbols = bytes.map { byteToId[Int($0)] }
        while symbols.count > 1 {
            var best: (rank: Int, pos: Int, id: Int)?
            for p in 0 ..< symbols.count - 1 {
                let key = UInt64(UInt32(symbols[p])) << 32 | UInt64(UInt32(symbols[p + 1]))
                if let m = merges[key], best == nil || m.rank < best!.rank { best = (m.rank, p, m.id) }
            }
            guard let b = best else { break }
            symbols[b.pos] = b.id
            symbols.remove(at: b.pos + 1)
        }
        return symbols
    }

    /// GPT-2 の bytes_to_unicode の逆写像。
    static let unicodeToByte: [Unicode.Scalar: UInt8] = {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var map: [Unicode.Scalar: UInt8] = [:]
        for (b, c) in zip(bs, cs) { map[Unicode.Scalar(UInt32(c))!] = UInt8(b) }
        return map
    }()

    private static func decodeByteLevel(_ token: String, _ table: [Unicode.Scalar: UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(token.unicodeScalars.count)
        for s in token.unicodeScalars {
            guard let b = table[s] else { return nil }
            out.append(b)
        }
        return out
    }
}

public enum D1TokenizerError: Error, CustomStringConvertible {
    /// d1 の tokenizer.json と違う構成（このトークナイザでは正しい列を保証できない）。
    case unsupported(String)
    /// 選択肢・yes/no に 1 トークンの表記が無い。
    case noSingleTokenAlias(String)

    public var description: String {
        switch self {
        case let .unsupported(s): return "D1Tokenizer: 未対応のトークナイザ構成: \(s)"
        case let .noSingleTokenAlias(s): return "D1Tokenizer: 1 トークンの表記が無い: \(s)"
        }
    }
}
