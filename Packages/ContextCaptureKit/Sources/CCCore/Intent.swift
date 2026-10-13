import Foundation

/// 注釈から推定する意図（PRD F-09）。JSON では小文字の文字列で表す。
/// 辞書のキーにしても JSON オブジェクト（`{"code": 0.84}`）になるよう `CodingKeyRepresentable` に準拠する。
public enum Intent: String, Codable, CaseIterable, Sendable, Hashable, CodingKeyRepresentable {
    case todo
    case research
    case code
    case note
    case schedule

    /// これ未満の確信度は「未分類」（intent = nil）として保存する。0.7 ちょうどは分類済み。
    public static let confidenceThreshold: Double = 0.7
}

/// 確率分布から保存すべき意図を決める純粋関数。
/// 最大確率の意図を選び、その確率が `threshold` 未満なら intent を nil（未分類）にする。確信度はどちらの場合も返す。
/// 確率が空なら `(nil, 0)`。同率は `Intent.allCases` の順で先のものを採る。
public func resolveIntent(
    probabilities: [Intent: Double],
    threshold: Double = Intent.confidenceThreshold
) -> (intent: Intent?, confidence: Double) {
    var best: (Intent, Double)?
    for candidate in Intent.allCases {
        guard let p = probabilities[candidate] else { continue }
        if best == nil || p > best!.1 { best = (candidate, p) }
    }
    guard let (top, confidence) = best else { return (nil, 0) }
    return (confidence < threshold ? nil : top, confidence)
}
