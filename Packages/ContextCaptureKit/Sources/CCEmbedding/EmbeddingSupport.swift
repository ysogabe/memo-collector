import Foundation

/// CCEmbedding のエラー。
public enum EmbeddingError: Error, Equatable, CustomStringConvertible {
    /// モデルディレクトリに読み込みに要るファイルが無い（`cc-models prepare embedding` が未実行）。
    case modelFilesMissing(directory: String, missing: [String])
    /// モデルのファイルが壊れている・形が違う。
    case invalidAsset(String)
    /// 画像を処理できない（大きさ 0 など）。
    case invalidImage(String)
    /// Core ML の推論が失敗した・出力が想定と違う。
    case predictionFailed(String)

    public var description: String {
        switch self {
        case let .modelFilesMissing(dir, missing):
            return "埋め込みモデルのファイルが足りません（\(dir)）: \(missing.joined(separator: ", "))。cc-models prepare embedding を実行してください"
        case let .invalidAsset(s): return "埋め込みモデルのファイルが不正です: \(s)"
        case let .invalidImage(s): return "画像を埋め込みにできません: \(s)"
        case let .predictionFailed(s): return "埋め込みの推論に失敗しました: \(s)"
        }
    }
}

/// EmbeddingGemma 2 の入力文字列の組み立て（sentence-transformers の `prompts` と `poc/scripts/exp04_embedding.py`）。
public enum EmbeddingPrompt {
    /// 検索クエリ: `task: search result | query: {text}`。
    public static func query(_ text: String) -> String { "task: search result | query: \(text)" }
    /// 文書: `title: {title} | text: {text}`（title が nil・空なら `none`）。
    public static func document(text: String, title: String?) -> String { "title: \(titleOrNone(title)) | text: \(text)" }
    /// 融合（文書 + 画像）: `title: {title} | text: {text} <|image|>`。`<|image|>` は画像トークン列に置き換える。
    public static func fused(text: String, title: String?) -> String { document(text: text, title: title) + " " + imagePlaceholder }
    /// HF の processor が画像トークン列に展開する目印。
    public static let imagePlaceholder = "<|image|>"

    static func titleOrNone(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "none" }
        return title
    }
}

/// ベクトルの後処理。
public enum EmbeddingVector {
    /// Matryoshka: 先頭 `dimension` 個を切り出して L2 正規化する（EmbeddingGemma 2 の 512/256/128 次元の作り方）。
    /// 全部 0 なら 0 のまま返す。
    public static func truncateAndNormalize(_ v: [Float], to dimension: Int) -> [Float] {
        normalize(Array(v.prefix(dimension)))
    }

    /// L2 正規化（ノルム 0 ならそのまま）。
    public static func normalize(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 0, norm.isFinite else { return v }
        return v.map { $0 / norm }
    }

    /// コサイン類似度。
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "dimension mismatch")
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
