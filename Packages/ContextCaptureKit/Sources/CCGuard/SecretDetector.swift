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
        var findings: [SecretFinding] = []
        // 行ごとに「既に秘密とした範囲」を持ち、後のパターンが同じ範囲を二重に取らないようにする。
        var claimed: [Int: [NSRange]] = [:]

        func claim(_ lineIndex: Int, _ range: NSRange) -> Bool {
            if claimed[lineIndex, default: []].contains(where: { NSIntersectionRange($0, range).length > 0 }) { return false }
            claimed[lineIndex, default: []].append(range)
            return true
        }

        func box(_ lineIndex: Int, _ range: NSRange) -> CGRect {
            let line = lines[lineIndex]
            if let r = Range(range, in: line.text), let b = line.boxForRange(r), b.width > 0, b.height > 0 {
                return b
            }
            return line.bbox
        }

        for pattern in patterns {
            for (i, line) in lines.enumerated() {
                let ns = line.text as NSString
                let matches = pattern.regex.matches(in: line.text, range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    switch pattern.mode {
                    case .value:
                        let v = m.range(withName: "v")
                        let range = v.location != NSNotFound ? v : m.range
                        if claim(i, range) {
                            findings.append(SecretFinding(kind: pattern.kind, bbox: box(i, range)))
                        }
                    case .label:
                        guard let value = labelValue(match: m.range, lineIndex: i, lines: lines) else { continue }
                        if claim(value.line, value.range) {
                            findings.append(SecretFinding(kind: pattern.kind, bbox: box(value.line, value.range)))
                        }
                    }
                }
            }
        }
        return findings
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
