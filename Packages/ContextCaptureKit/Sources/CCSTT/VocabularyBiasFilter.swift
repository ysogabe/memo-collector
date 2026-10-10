import CoreML
import Foundation
import WhisperKit

/// 語彙の綴りを構成するトークン列へ logit を加算する WhisperKit の `LogitsFiltering`（浅い融合 / contextual biasing）。
///
/// 各語を「先頭に空白あり」「なし」の 2 通りでトークン化し、直前までの出力の末尾が語の途中まで一致していれば
/// 次のトークンに `continuationBias`、語の先頭トークンには `startBias` を加える。
/// 先頭に小さく、続きに大きく足すのは、語に入るかどうかは音響に任せ、入ったら綴りを最後まで通すため。
final class VocabularyBiasFilter: LogitsFiltering {
    /// 語ごとのトークン列（空白あり / なしの両方）。
    let sequences: [[Int]]
    let startBias: Float
    let continuationBias: Float
    /// これ以上の ID は特殊トークン（バイアス対象外）。
    let specialTokenBegin: Int

    init(sequences: [[Int]], startBias: Float, continuationBias: Float, specialTokenBegin: Int) {
        self.sequences = sequences.filter { !$0.isEmpty && $0.allSatisfy { $0 < specialTokenBegin } }
        self.startBias = startBias
        self.continuationBias = continuationBias
        self.specialTokenBegin = specialTokenBegin
    }

    /// 次に足すトークンとバイアス（同じトークンに複数かかるときは最大値）。
    func biases(after tokens: [Int]) -> [Int: Float] {
        var out: [Int: Float] = [:]
        for seq in sequences {
            // 末尾 k トークンが seq の先頭 k トークンと一致する最長の k（seq.count 未満）を探す
            var matched = 0
            var k = min(seq.count - 1, tokens.count)
            while k > 0 {
                if Array(tokens.suffix(k)) == Array(seq.prefix(k)) { matched = k; break }
                k -= 1
            }
            let next = seq[matched]
            let bias = matched == 0 ? startBias : continuationBias
            if bias > (out[next] ?? -.infinity) { out[next] = bias }
        }
        return out.filter { $0.value != 0 }
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        let vocabSize = logits.shape.last?.intValue ?? 0
        for (token, bias) in biases(after: tokens) where token < vocabSize {
            let index: [NSNumber] = [0, 0, NSNumber(value: token)]
            let current = logits[index].floatValue
            guard current.isFinite else { continue } // 抑制済み（-inf）は戻さない
            logits[index] = NSNumber(value: current + bias)
        }
        return logits
    }
}
