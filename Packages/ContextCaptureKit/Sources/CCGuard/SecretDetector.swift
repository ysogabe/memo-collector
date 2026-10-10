import CCCore
import CoreGraphics
import Foundation

/// OCR の 1 行（Vision の 1 observation）。座標は正規化・**左上原点**。
public struct OCRLine {
    public var text: String
    public var bbox: CGRect
    /// 行内の文字範囲の bbox（正規化・左上原点）。求められなければ nil（呼び出し側が行全体で代用する）。
    public var boxForRange: (Range<String.Index>) -> CGRect?

    public init(text: String, bbox: CGRect, boxForRange: @escaping (Range<String.Index>) -> CGRect? = { _ in nil }) {
        self.text = text
        self.bbox = bbox
        self.boxForRange = boxForRange
    }
}

/// OCR 行に正規表現を当てて秘密情報の位置を返す純粋ロジック（Vision 非依存。単体テスト用に分けてある）。
///
/// ⚠️ 検出した文字列そのものは返さない・ログに出さない（秘密をアプリの外へ持ち出さないため）。
public struct SecretDetector: Sendable {
    public let patterns: [SecretPattern]

    /// 見出しの下の行を値とみなす縦の距離（見出し行の高さの何倍まで）。
    static let valueBelowMaxGap: CGFloat = 2.0
    /// 値とみなす文字列の長さの範囲（これより短いものは「?」等の記号、長いものは段落）。
    static let valueLengthRange = 4...200
    /// 値とみなす文字列に含まれてよい空白の数（段落を値と取り違えないため）。
    static let valueMaxSpaces = 2
    /// 見出しの前に許す文字数（`DB_PASSWORD`、`ワンタイムパスワード` 程度）。これより長いと文中の言及とみなす。
    static let labelMaxPrefix = 16
    /// 伏せ字とみなす文字（空白も含む）。値がこれだけなら秘密は表示されていない。
    static let maskCharacters: Set<Character> = ["●", "•", "*", "·", "∙", "⋅", "◦", "○", "◯", "・", "＊", "⚫", "⏺", ".", "…", "x", "X"]

    public init(patterns: [SecretPattern] = SecretPattern.defaults) {
        self.patterns = patterns
    }

    public func detect(lines: [OCRLine]) -> [SecretFinding] {
        // 行ごとの一致範囲（パターンの評価順つき）。重なった範囲は最後に和集合へまとめる
        // （狭い方だけを bbox にすると広い方の秘密が塗り残されるため）。kind は先に評価したパターンのものを採る。
        var spans: [Int: [(range: NSRange, order: Int, kind: String)]] = [:]
        var blockFindings: [SecretFinding] = []

        for (order, pattern) in patterns.enumerated() {
            for (i, line) in lines.enumerated() {
                let ns = line.text as NSString
                let matches = pattern.regex.matches(in: line.text, range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    switch pattern.mode {
                    case .value:
                        let v = m.range(withName: "v")
                        let range = v.location != NSNotFound ? v : m.range
                        spans[i, default: []].append((range, order, pattern.kind))
                    case .label:
                        guard let value = labelValue(match: m.range, lineIndex: i, lines: lines) else { continue }
                        spans[value.line, default: []].append((value.range, order, pattern.kind))
                    case .blockStart:
                        blockFindings.append(SecretFinding(kind: pattern.kind, bbox: blockBox(headerIndex: i, lines: lines)))
                    }
                }
            }
        }

        var findings: [SecretFinding] = []
        for i in spans.keys.sorted() {
            for merged in Self.mergeOverlapping(spans[i]!) {
                findings.append(SecretFinding(kind: merged.kind, bbox: box(lines[i], merged.range)))
            }
        }
        return findings + blockFindings
    }

    /// 重なる（または接する）範囲を和集合にまとめる。kind は含まれる中で最も先に評価したパターンのもの。
    static func mergeOverlapping(_ items: [(range: NSRange, order: Int, kind: String)]) -> [(range: NSRange, kind: String)] {
        let sorted = items.sorted { $0.range.location < $1.range.location }
        var out: [(range: NSRange, order: Int, kind: String)] = []
        for item in sorted {
            if var last = out.last, item.range.location <= NSMaxRange(last.range) {
                last.range = NSUnionRange(last.range, item.range)
                if item.order < last.order { last.order = item.order; last.kind = item.kind }
                out[out.count - 1] = last
            } else {
                out.append(item)
            }
        }
        return out.map { ($0.range, $0.kind) }
    }

    private func box(_ line: OCRLine, _ range: NSRange) -> CGRect {
        if range.location == 0, range.length == (line.text as NSString).length { return line.bbox }
        if let r = Range(range, in: line.text), let b = line.boxForRange(r), b.width > 0, b.height > 0 {
            return b
        }
        return line.bbox
    }

    /// PEM の END 行（見出しと対）と、END が見えないときの本体行（base64 らしい行）。
    static let blockEnd = try! NSRegularExpression(pattern: #"END [A-Z ]*PRIVATE KEY"#)
    static let base64Characters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    /// 本体の行と行の間に許す隙間（行の高さの何倍まで）。これより大きい空きでブロックの終わりとみなす。
    static let blockLineMaxGap: CGFloat = 1.5
    /// 本体行に許す base64 以外の文字の割合（OCR の誤読で `-` `.` `|` 等が 1〜2 個混ざる分）。
    static let blockMaxForeignRatio = 0.1
    /// 本体らしくない行が連続していくつまでなら走査を続けるか（OCR が 1 行だけ崩れても残りを塗り残さない）。
    static let blockMaxConsecutiveMismatches = 1

    /// PEM 本体の行らしいか。長さは問わない（最終行は短く `=` で終わることがある）。base64 外の文字は 10% 未満まで許す。
    static func looksLikeBase64Body(_ text: String) -> Bool {
        let compact = text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        guard !compact.isEmpty else { return false }
        let foreign = compact.filter { !base64Characters.contains($0) }.count
        return Double(foreign) / Double(compact.count) < blockMaxForeignRatio
    }

    /// 鍵ブロック全体の bbox。見出し → END（同じ列で下にある最も近いもの）までの行をすべて含める。
    /// END が無ければ（画面外・OCR 漏れ）、見出しの下に縦に連続する base64 らしい行の塊の終わりまで。
    func blockBox(headerIndex: Int, lines: [OCRLine]) -> CGRect {
        let header = lines[headerIndex].bbox
        let h = max(header.height, 0.001)
        func sameColumn(_ r: CGRect) -> Bool { abs(r.minX - header.minX) <= h * 3 }
        let below = lines.indices
            .filter { $0 != headerIndex && lines[$0].bbox.minY >= header.minY + h * 0.5 && sameColumn(lines[$0].bbox) }
            .sorted { lines[$0].bbox.minY < lines[$1].bbox.minY }

        if let endIndex = below.first(where: { j in
            let t = lines[j].text
            return Self.blockEnd.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
        }) {
            let endBox = lines[endIndex].bbox
            var box = header.union(endBox)
            let column = box
            // 見出しと END の間で、見出し〜END の列と横に重なる行はすべて本体とみなす（OCR の崩れた行も含める）。
            for j in lines.indices where j != headerIndex {
                let r = lines[j].bbox
                if r.midY > header.minY, r.midY < endBox.maxY, r.minX < column.maxX, r.maxX > column.minX { box = box.union(r) }
            }
            return box
        }

        // END が無い: 縦の間隔が小さいうちは走査を続ける。本体らしくない行は連続
        // `blockMaxConsecutiveMismatches` 行まで保留し、その後に本体らしい行が続けば保留分ごと含める。
        var box = header
        var bottom = header.maxY
        var pending: [CGRect] = []
        for j in below {
            let r = lines[j].bbox
            guard r.minY - bottom <= h * Self.blockLineMaxGap else { break }
            if Self.looksLikeBase64Body(lines[j].text) {
                for p in pending { box = box.union(p) }
                pending = []
                box = box.union(r)
            } else {
                guard pending.count < Self.blockMaxConsecutiveMismatches else { break }
                pending.append(r)
            }
            bottom = r.maxY
        }
        return box
    }

    /// 見出しに対応する値の位置。値が無い・伏せ字・値らしくないなら nil。
    func labelValue(match: NSRange, lineIndex: Int, lines: [OCRLine]) -> (line: Int, range: NSRange)? {
        let line = lines[lineIndex]
        let ns = line.text as NSString
        let prefix = ns.substring(to: match.location).trimmingCharacters(in: .whitespaces)
        guard prefix.count <= Self.labelMaxPrefix else { return nil }

        // 見出しの後ろ: 括弧書き（「（表示中）」等）を飛ばし、区切り（: = ：）があればその後を値とする。
        let afterStart = match.location + match.length
        let after = ns.substring(from: afterStart)
        let scanner = Scanner(string: after)
        scanner.charactersToBeSkipped = nil
        _ = scanner.scanCharacters(from: .whitespaces)
        if scanner.scanString("（") != nil { _ = scanner.scanUpToString("）"); _ = scanner.scanString("）") }
        else if scanner.scanString("(") != nil { _ = scanner.scanUpToString(")"); _ = scanner.scanString(")") }
        _ = scanner.scanCharacters(from: .whitespaces)
        let hasDelimiter = scanner.scanCharacters(from: CharacterSet(charactersIn: ":=：")) != nil
        _ = scanner.scanCharacters(from: .whitespaces)
        let consumed = NSRange(after.startIndex..<scanner.currentIndex, in: after).length
        let rest = String(after[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)

        if !rest.isEmpty {
            // 同じ行に続きがある: 区切りの後なら値。区切りが無いなら文中の言及（"Enter your password to …"）なので当てない。
            guard hasDelimiter else { return nil }
            guard Self.looksLikeValue(rest) else { return nil }
            let loc = afterStart + consumed
            return (lineIndex, NSRange(location: loc, length: ns.length - loc))
        }

        // 見出しだけの行: すぐ下で横位置が重なる行を値とみなす。
        let b = line.bbox
        var best: (index: Int, gap: CGFloat)?
        for (j, other) in lines.enumerated() where j != lineIndex {
            let o = other.bbox
            let gap = o.minY - b.maxY
            guard gap >= -b.height * 0.5, gap <= b.height * Self.valueBelowMaxGap else { continue }
            guard o.minX < b.maxX, o.maxX > b.minX else { continue }
            guard abs(o.minX - b.minX) <= b.height * 3 else { continue }
            if best == nil || gap < best!.gap { best = (j, gap) }
        }
        guard let best else { return nil }
        let valueText = lines[best.index].text.trimmingCharacters(in: .whitespaces)
        guard Self.looksLikeValue(valueText) else { return nil }
        return (best.index, NSRange(location: 0, length: (lines[best.index].text as NSString).length))
    }

    /// 秘密の値として表示されていそうか（伏せ字・短すぎ・段落は除く）。
    static func looksLikeValue(_ s: String) -> Bool {
        guard valueLengthRange.contains(s.count) else { return false }
        if s.allSatisfy({ $0.isWhitespace || maskCharacters.contains($0) }) { return false }
        // 伏せ字が大半（OCR が ● の列を混ぜて読むことがある）なら表示されていないとみなす。
        let masked = s.filter { maskCharacters.contains($0) && $0 != "." && $0 != "x" && $0 != "X" }.count
        if Double(masked) / Double(s.count) >= 0.5 { return false }
        // 表示された秘密（キー・パスワード）はほぼ ASCII。日本語の見出しやメニュー項目を値と取り違えないため 8 割以上を求める。
        let ascii = s.unicodeScalars.filter { $0.isASCII }.count
        if Double(ascii) / Double(s.unicodeScalars.count) < 0.8 { return false }
        return s.filter(\.isWhitespace).count <= valueMaxSpaces
    }
}
