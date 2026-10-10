import Foundation

/// 意図・日時言及の推定結果（PRD F-09）。ContextRecord の `triage` 欄にそのまま入る。
/// 確信度が `Intent.confidenceThreshold` 未満なら `intent` は nil（未分類）だが、`intentConfidence` と確率は残す。
public struct TriageResult: Codable, Sendable, Equatable {
    /// 未分類なら nil。ユーザーが手で変えた場合もここを書き換える。
    public var intent: Intent?
    /// 最大確率の意図の確率（未分類でも入る）。
    public var intentConfidence: Double
    /// 全意図の確率（省略可。PRD の例には無い）。
    public var intentProbabilities: [Intent: Double]?
    public var mentionsDatetime: Bool
    /// 「日時の言及あり」の確率（省略可）。
    public var datetimeProbability: Double?
    /// 推定したモデルとリビジョン（例: "LiquidAI/d1-3B@051bcc4"）。
    public var model: String

    public init(
        intent: Intent?,
        intentConfidence: Double,
        intentProbabilities: [Intent: Double]? = nil,
        mentionsDatetime: Bool,
        datetimeProbability: Double? = nil,
        model: String
    ) {
        self.intent = intent
        self.intentConfidence = intentConfidence
        self.intentProbabilities = intentProbabilities
        self.mentionsDatetime = mentionsDatetime
        self.datetimeProbability = datetimeProbability
        self.model = model
    }

    /// 「日時の言及あり」とみなす確率の下限。
    public static let datetimeThreshold: Double = 0.5

    /// 確率分布から結果を組み立てる（未分類判定は `resolveIntent` に従う）。
    public init(
        probabilities: [Intent: Double],
        datetimeProbability: Double,
        model: String,
        threshold: Double = Intent.confidenceThreshold
    ) {
        let decision = resolveIntent(probabilities: probabilities, threshold: threshold)
        self.init(
            intent: decision.intent,
            intentConfidence: decision.confidence,
            intentProbabilities: probabilities,
            mentionsDatetime: datetimeProbability >= Self.datetimeThreshold,
            datetimeProbability: datetimeProbability,
            model: model
        )
    }

    /// 未分類（確信度不足）か。
    public var isUnclassified: Bool { intent == nil }

    enum CodingKeys: String, CodingKey {
        case intent
        case intentConfidence = "intent_confidence"
        case intentProbabilities = "intent_probabilities"
        case mentionsDatetime = "mentions_datetime"
        case datetimeProbability = "datetime_probability"
        case model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intent = try c.decodeIfPresent(Intent.self, forKey: .intent)
        intentConfidence = try c.decode(Double.self, forKey: .intentConfidence)
        intentProbabilities = try c.decodeIfPresent([Intent: Double].self, forKey: .intentProbabilities)
        mentionsDatetime = try c.decode(Bool.self, forKey: .mentionsDatetime)
        datetimeProbability = try c.decodeIfPresent(Double.self, forKey: .datetimeProbability)
        model = try c.decode(String.self, forKey: .model)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(intent, forKey: .intent)
        try c.encode(intentConfidence, forKey: .intentConfidence)
        try c.encodeIfPresent(intentProbabilities, forKey: .intentProbabilities)
        try c.encode(mentionsDatetime, forKey: .mentionsDatetime)
        try c.encodeIfPresent(datetimeProbability, forKey: .datetimeProbability)
        try c.encode(model, forKey: .model)
    }
}
