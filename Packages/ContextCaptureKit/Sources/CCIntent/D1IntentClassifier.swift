import CCCore
import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// d1-3B（言語モデル部、MLX 8bit）で注釈テキストから意図と日時言及を推定する。
///
/// - モデルは `CCPaths.modelDirectory(.d1)`（`d1-3b-text-q8/`）から**初回の classify で**読み込む（遅延ロード）。
///   `load()` を呼べば先に読み込める。`unload()` で解放し、MLX のバッファキャッシュも返す。
/// - 1 質問 1 forward（chain）。意図（5 択）と日時言及（yes/no）で 2 forward。出力トークンは生成しない。
/// - トークン列は `D1Tokenizer`（HF と一致する自前実装）で作る。swift-transformers の AutoTokenizer は使わない。
public actor D1IntentClassifier: IntentClassifying, ModelUnloadable {
    /// TriageResult.model に入れる識別子（元 repo@revision + 変換）。
    public static let defaultModelIdentifier = "LiquidAI/d1-3B@051bcc4+mlx-q8"

    public nonisolated let modelDirectory: URL
    public nonisolated let modelIdentifier: String

    private var loaded: Loaded?
    /// 最終位置だけ語彙へ射影するか（false なら全位置の logits を作る。スパイクと同じ経路。比較・診断用）。
    var lastPositionOnly = true
    func setLastPositionOnly(_ v: Bool) { lastPositionOnly = v }
    /// 直近のロードの計測値（ロードしたことが無ければ nil）。
    public private(set) var lastLoadMetrics: D1LoadMetrics?

    private final class Loaded {
        let model: LFM2Model
        let prompt: D1Prompt
        /// 最終 hidden → 語彙 logits（tie_word_embeddings なので埋め込み行列そのもの）。
        let lmHead: Embedding?
        let intentGroups: [[Int]]
        let deadlineGroups: [[Int]]
        init(model: LFM2Model, prompt: D1Prompt, lmHead: Embedding?, intentGroups: [[Int]], deadlineGroups: [[Int]]) {
            self.model = model
            self.prompt = prompt
            self.lmHead = lmHead
            self.intentGroups = intentGroups
            self.deadlineGroups = deadlineGroups
        }
    }

    /// MLX のバッファキャッシュの上限の既定（256MB）。
    ///
    /// 上限を付けないと、d1 の forward で解放したバッファを MLX がキャッシュに溜め続け、d1 常駐中の footprint が
    /// 3.3〜3.6GB 余計に増える（docs/e2e/report.md §4・§7 問題 2）。E2E（3 モデル同時、`CC_E2E_MLX_CACHE_LIMIT_MB=256`、
    /// 同 §8）で 256MB にすると、トリアージ中のピークが 7,224 → 4,084MB、MLX キャッシュが 3,587 → 269MB に下がり、
    /// d1 1 件（2 問）の p50 は 0.47 → 0.48 秒・意図と日時の確率（最大 |Δp| 0.04258）・正解数は同一だった。
    public static let defaultMLXCacheLimitBytes = 256 << 20

    /// `load()` で設定する MLX のキャッシュ上限（バイト）。nil なら触らない（MLX の既定 = 実質無制限）。
    /// ⚠️ `Memory.cacheLimit` はプロセス全体で 1 つ（同じプロセスの他の MLX 利用にも効く）。
    public nonisolated let mlxCacheLimitBytes: Int?

    public init(
        modelDirectory: URL = CCPaths.resolve().modelDirectory(.d1),
        modelIdentifier: String = D1IntentClassifier.defaultModelIdentifier,
        mlxCacheLimitBytes: Int? = D1IntentClassifier.defaultMLXCacheLimitBytes
    ) {
        self.modelDirectory = modelDirectory
        self.modelIdentifier = modelIdentifier
        self.mlxCacheLimitBytes = mlxCacheLimitBytes
    }

    public var isLoaded: Bool { loaded != nil }

    /// 読み込む（済んでいれば何もしない）。計測値を返す。
    @discardableResult
    public func load() throws -> D1LoadMetrics {
        if loaded != nil, let m = lastLoadMetrics { return m }
        let fm = FileManager.default
        for name in ["config.json", "tokenizer.json"] where !fm.fileExists(atPath: modelDirectory.appendingPathComponent(name).path) {
            throw D1IntentError.modelNotFound(modelDirectory.appendingPathComponent(name))
        }
        // 重みの読み込みより先に（読み込み中に解放されるバッファもキャッシュに溜めない）。
        if let limit = mlxCacheLimitBytes { Memory.cacheLimit = limit }
        let rssBefore = Self.residentBytes()
        let t0 = Date()
        let tokenizer = try D1Tokenizer(tokenizerJSON: modelDirectory.appendingPathComponent("tokenizer.json"))
        let tokenizerSeconds = Date().timeIntervalSince(t0)

        let cfgData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        let cfg = try JSONDecoder().decode(LFM2Configuration.self, from: cfgData)
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: cfgData)
        let model = LFM2Model(cfg)
        // `perLayerQuantization` は config の全体設定（`quantization`）も含むので、こちらだけ渡せば同じ（`quantization` は非推奨）。
        try loadWeights(modelDirectory: modelDirectory, model: model, perLayerQuantization: base.perLayerQuantization)
        let lmHead = model.namedModules().first { $0.0 == "model.embed_tokens" }?.1 as? Embedding

        let prompt = D1Prompt(tokenizer: tokenizer)
        loaded = Loaded(model: model, prompt: prompt, lmHead: lmHead,
                        intentGroups: try prompt.readoutIds(D1Questions.intent),
                        deadlineGroups: try prompt.readoutIds(D1Questions.deadline))
        let metrics = D1LoadMetrics(
            loadSeconds: Date().timeIntervalSince(t0), tokenizerSeconds: tokenizerSeconds,
            mlxActiveBytes: Memory.activeMemory, mlxPeakBytes: Memory.peakMemory,
            residentBytesBefore: rssBefore, residentBytesAfter: Self.residentBytes())
        lastLoadMetrics = metrics
        return metrics
    }

    public func unload() {
        guard loaded != nil else { return }
        loaded = nil
        Memory.clearCache()
    }

    public func classify(text: String) async throws -> TriageResult {
        let p = try probabilities(text: text)
        var intents: [Intent: Double] = [:]
        for (label, prob) in zip(D1Questions.intentLabels, p.intent) { intents[label] = prob }
        return TriageResult(probabilities: intents, datetimeProbability: p.datetime, model: modelIdentifier)
    }

    /// 2 質問の確率（意図は `D1Questions.intentLabels` の順、日時は「言及あり」の確率）。
    public func probabilities(text: String) throws -> D1Probabilities {
        if loaded == nil { try load() }
        let l = loaded!
        let intent = try answer(l, ids: l.prompt.encode(state: text, question: D1Questions.intent), groups: l.intentGroups)
        let deadline = try answer(l, ids: l.prompt.encode(state: text, question: D1Questions.deadline), groups: l.deadlineGroups)
        return D1Probabilities(intent: intent, datetime: deadline[0])
    }

    /// 与えた ID 列で 1 forward し、readout した確率を返す（テスト・診断用）。
    public func answer(ids: [Int], question: D1Question) throws -> [Double] {
        if loaded == nil { try load() }
        let l = loaded!
        return try answer(l, ids: ids, groups: l.prompt.readoutIds(question))
    }

    private func answer(_ l: Loaded, ids: [Int], groups: [[Int]]) throws -> [Double] {
        guard !ids.isEmpty else { throw D1IntentError.emptyInput }
        let x = MLXArray(ids.map { Int32($0) }).reshaped([1, ids.count])
        let flat = Array(Set(groups.flatMap { $0 })).sorted()
        let logits: MLXArray
        if lastPositionOnly, let head = l.lmHead {
            // 最終位置だけ語彙へ射影する（全位置の 128000 次元 logits を作らない）
            let h = l.model.model(x, cache: nil)[0, ids.count - 1]
            logits = head.asLinear(h).asType(.float32)
        } else {
            logits = l.model(x, cache: nil)[0, ids.count - 1].asType(.float32)
        }
        let sel = logits[MLXArray(flat.map { Int32($0) })]
        eval(sel)
        let values = sel.asArray(Float.self)
        var at: [Int: Double] = [:]
        for (i, id) in flat.enumerated() { at[id] = Double(values[i]) }
        return D1Prompt.readout(groups: groups) { at[$0]! }
    }

    /// プロセスの常駐メモリ（RSS, bytes）。取れなければ -1。
    public static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : -1
    }
}

/// 2 質問の確率。
public struct D1Probabilities: Sendable, Equatable {
    /// 意図の確率（`D1Questions.intentLabels` の順）。
    public var intent: [Double]
    /// 日時言及ありの確率。
    public var datetime: Double
}

/// 初回ロードの計測値。
public struct D1LoadMetrics: Sendable, Equatable {
    /// tokenizer.json の読み込みを含むロード全体の秒数。
    public var loadSeconds: Double
    /// tokenizer.json の読み込み秒数。
    public var tokenizerSeconds: Double
    /// MLX のアクティブメモリ（ロード直後）。
    public var mlxActiveBytes: Int
    /// MLX のピークメモリ（プロセス開始以来）。
    public var mlxPeakBytes: Int
    /// プロセス RSS（ロード前 / 後）。重みは mmap されるので MLX のアクティブメモリと一致しない。
    public var residentBytesBefore: Int
    public var residentBytesAfter: Int
}

public enum D1IntentError: Error, CustomStringConvertible {
    case modelNotFound(URL)
    case emptyInput

    public var description: String {
        switch self {
        case let .modelNotFound(url): return "d1 モデルのファイルが無い: \(url.path)（`cc-models prepare d1` で準備する）"
        case .emptyInput: return "空の入力"
        }
    }
}

extension D1IntentClassifier: ModelPreparable {
    /// `load()` と同じ（計測値を捨てる）。`ModelPreparable` として他のモデルと同じ手順で温めるため。
    public func prepare() async throws {
        _ = try load()
    }
}

extension D1IntentError: ModelReadinessReporting {
    /// モデルのファイルが無い（`cc-models prepare d1` 前・オンボーディング中）のは未準備。
    public var isModelNotReady: Bool {
        if case .modelNotFound = self { return true }
        return false
    }
}
