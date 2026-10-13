import CCCore
@preconcurrency import CoreML
import CoreGraphics
import Foundation

/// EmbeddingGemma 2（`FluidInference/embeddinggemma-2-coreml` revision 3f978dd）の Core ML 版による埋め込み。
///
/// - 出力: 先頭 `dimension`（既定 256）次元を切り出して L2 正規化したもの（Matryoshka）
/// - クエリ: `task: search result | query: {text}`
/// - 文書: `title: {title} | text: {text}`、画像があれば `… <|image|>` + 画像の融合
/// - 遅延ロード: 最初の埋め込みで必要な塔だけ読む（テキスト塔 / 視覚塔は別々）。`unload()` で両方解放
/// - **初回ロードは ANE 向けコンパイルで数分**（テキスト 6 関数で約 2 分、画像 280 で約 1 分）。キャッシュは
///   **実行バイナリ単位**なので、アプリ本体のプロセスで `prepare()` を呼んで温める（`cc-models` で温めても効かない）
/// - 推論は専用の直列キューで 1 件ずつ、`autoreleasepool` の中で行う（無いと Core ML の入出力が溜まって 2GB 超まで膨らむ）
public actor CoreMLEmbedder: Embedder, ModelUnloadable {
    public struct Configuration: Sendable, Equatable {
        /// `EmbeddingGemma2Text.mlmodelc` などを置いたディレクトリ（`CCPaths.modelDirectory(.embedding)`）。
        public var modelDirectory: URL
        /// 画像トークン数。変えると埋め込みの中身が変わるので索引の作り直しが要る。
        public var imageTokens: ImageTokenBudget
        public var textComputeUnits: EmbeddingComputeUnits
        public var visionComputeUnits: EmbeddingComputeUnits
        /// 出力次元（768 以下。MVP の索引は 256）。
        public var dimension: Int

        public init(
            modelDirectory: URL = CCPaths.resolve().modelDirectory(.embedding),
            imageTokens: ImageTokenBudget = .tokens280,
            textComputeUnits: EmbeddingComputeUnits = .cpuAndNeuralEngine,
            visionComputeUnits: EmbeddingComputeUnits = .cpuAndNeuralEngine,
            dimension: Int = 256
        ) {
            self.modelDirectory = modelDirectory
            self.imageTokens = imageTokens
            self.textComputeUnits = textComputeUnits
            self.visionComputeUnits = visionComputeUnits
            self.dimension = min(max(dimension, 1), EmbeddingGemma2TextTower.outputDimension)
        }

        /// 索引の互換性を表す文字列。保存しておき、変わったら索引を作り直す（計算ユニットは含めない: 差はコサイン 0.999 台）。
        public var indexSignature: String {
            "embeddinggemma-2-coreml@\(Self.modelRevision.prefix(7))/d\(dimension)/img\(imageTokens.rawValue)"
        }

        /// 前提にしているモデルの revision（CCModels の `EmbeddingModelPreparer.revision` と同じ）。
        public static let modelRevision = "3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4"
    }

    /// `prepare()` の結果（秒）。
    public struct PrepareReport: Sendable, Equatable {
        /// テキスト塔の読み込み（既に載っていれば 0）。
        public var textLoadSeconds: Double
        /// 視覚塔の読み込み（読まなかった・既に載っていれば 0）。
        public var visionLoadSeconds: Double
        /// 最初の推論（クエリ 1 件 + 画像 1 枚）。
        public var firstInferenceSeconds: Double
    }

    public nonisolated let configuration: Configuration
    public nonisolated var dimension: Int { configuration.dimension }

    private var text: EmbeddingGemma2TextTower?
    private var vision: EmbeddingGemma2VisionTower?
    private var textLoad: Task<EmbeddingGemma2TextTower, Error>?
    private var visionLoad: Task<EmbeddingGemma2VisionTower, Error>?
    /// `unload()` のたびに進める（読み込み途中で解放されたら、その結果を捨てる）。
    private var generation = 0
    private let queue = DispatchQueue(label: "CCEmbedding.CoreMLEmbedder.inference", qos: .utility)

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - ロード

    /// テキスト塔が載っているか（視覚塔は画像の埋め込みで別に読む）。
    public var isLoaded: Bool { text != nil }
    /// 視覚塔が載っているか。
    public var isVisionLoaded: Bool { vision != nil }

    /// 読み込みと最初の 1 回の推論を済ませる（ANE 向けの初回コンパイルを含むので**数分**かかりうる）。何度呼んでもよい。
    /// `includeVision: false` ならテキスト塔だけ（クエリしか埋め込まないプロセス向け）。
    @discardableResult
    public func prepare(includeVision: Bool = true) async throws -> PrepareReport {
        var t = Date()
        let textTower = try await loadText()
        let textSeconds = Date().timeIntervalSince(t)
        var visionSeconds = 0.0
        var visionTower: EmbeddingGemma2VisionTower?
        if includeVision {
            t = Date()
            visionTower = try await loadVision()
            visionSeconds = Date().timeIntervalSince(t)
        }
        t = Date()
        let ids = textTower.sequences.text(EmbeddingPrompt.query("warm up"))
        _ = try await run { try textTower.embed(ids: ids) }
        if let visionTower {
            let image = try Self.warmUpImage()
            _ = try await run { () -> [Float] in
                let p = try visionTower.preprocess(image)
                let tokens = try visionTower.imageTokens(p)
                return try textTower.embed(ids: textTower.sequences.image(softTokens: p.softTokens), imageTokens: tokens)
            }
        }
        return PrepareReport(textLoadSeconds: textSeconds, visionLoadSeconds: visionSeconds,
                             firstInferenceSeconds: Date().timeIntervalSince(t))
    }

    /// 両方の塔を解放する。次の埋め込みで読み直す（ANE のキャッシュが効いていれば数秒〜20 秒）。
    public func unload() async {
        generation += 1
        text = nil
        vision = nil
        textLoad = nil
        visionLoad = nil
    }

    private func loadText() async throws -> EmbeddingGemma2TextTower {
        if let text { return text }
        let task: Task<EmbeddingGemma2TextTower, Error>
        if let textLoad {
            task = textLoad
        } else {
            let dir = configuration.modelDirectory, units = configuration.textComputeUnits
            task = Task { try await EmbeddingGemma2TextTower.load(directory: dir, computeUnits: units) }
            textLoad = task
        }
        let gen = generation
        do {
            let tower = try await task.value
            if gen == generation {
                text = tower
                textLoad = nil
            }
            return tower
        } catch {
            if gen == generation { textLoad = nil }
            throw error
        }
    }

    private func loadVision() async throws -> EmbeddingGemma2VisionTower {
        if let vision { return vision }
        let task: Task<EmbeddingGemma2VisionTower, Error>
        if let visionLoad {
            task = visionLoad
        } else {
            let dir = configuration.modelDirectory, units = configuration.visionComputeUnits
            let budget = configuration.imageTokens
            task = Task { try await EmbeddingGemma2VisionTower.load(directory: dir, budget: budget, computeUnits: units) }
            visionLoad = task
        }
        let gen = generation
        do {
            let tower = try await task.value
            if gen == generation {
                vision = tower
                visionLoad = nil
            }
            return tower
        } catch {
            if gen == generation { visionLoad = nil }
            throw error
        }
    }

    // MARK: - Embedder

    public func embedQuery(_ text: String) async throws -> [Float] {
        truncate(try await queryEmbedding768(text))
    }

    public func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] {
        truncate(try await documentEmbedding768(text: text, title: title, image: image))
    }

    /// 画像だけの埋め込み（`<bos> <|image> 画像トークン <image|> <eos>`）。`dimension` 次元・L2 正規化済み。
    public func embedImage(_ image: CGImage) async throws -> [Float] {
        truncate(try await imageEmbedding768(image))
    }

    // MARK: - 768 次元（切り詰め前。テストと再索引の検証用）

    func queryEmbedding768(_ text: String) async throws -> [Float] {
        let tower = try await loadText()
        let ids = tower.sequences.text(EmbeddingPrompt.query(text))
        return try await run { try tower.embed(ids: ids) }
    }

    func documentEmbedding768(text: String, title: String?, image: CGImage?) async throws -> [Float] {
        let textTower = try await loadText()
        guard let image else {
            let ids = textTower.sequences.text(EmbeddingPrompt.document(text: text, title: title))
            return try await run { try textTower.embed(ids: ids) }
        }
        let visionTower = try await loadVision()
        let prompt = EmbeddingPrompt.fused(text: text, title: title)
        return try await run {
            let p = try visionTower.preprocess(image)
            let tokens = try visionTower.imageTokens(p)
            return try textTower.embed(ids: textTower.sequences.fused(prompt, softTokens: p.softTokens), imageTokens: tokens)
        }
    }

    func imageEmbedding768(_ image: CGImage) async throws -> [Float] {
        let textTower = try await loadText()
        let visionTower = try await loadVision()
        return try await run {
            let p = try visionTower.preprocess(image)
            let tokens = try visionTower.imageTokens(p)
            return try textTower.embed(ids: textTower.sequences.image(softTokens: p.softTokens), imageTokens: tokens)
        }
    }

    /// 融合の入力トークン列（テスト用: HF と一致するか）。
    func fusedTokenIDs(text: String, title: String?, image: CGImage) async throws -> [Int32] {
        let textTower = try await loadText()
        let n = try ImagePreprocessor.softTokens(for: image, budget: configuration.imageTokens)
        return textTower.sequences.fused(EmbeddingPrompt.fused(text: text, title: title), softTokens: n)
    }

    // MARK: - 下請け

    private nonisolated func truncate(_ v: [Float]) -> [Float] {
        EmbeddingVector.truncateAndNormalize(v, to: configuration.dimension)
    }

    /// 専用の直列キューで、1 件ごとに autoreleasepool を抜けながら実行する（協調スレッドプールを塞がない）。
    private nonisolated func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                cont.resume(with: Result { try autoreleasepool { try body() } })
            }
        }
    }

    /// 視覚塔の初回推論用（中身は何でもよい。480×288 の灰色の段階）。
    static func warmUpImage() throws -> CGImage {
        let w = 480, h = 288
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                px[i] = UInt8(x * 255 / w); px[i + 1] = UInt8(y * 255 / h); px[i + 2] = 128; px[i + 3] = 255
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(px) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw EmbeddingError.invalidImage("cannot create warm-up image") }
        return image
    }
}

extension ImagePreprocessor {
    /// 縮小後の大きさから決まる画像トークン数（推論せずに分かる）。
    static func softTokens(for image: CGImage, budget: ImageTokenBudget) throws -> Int {
        guard image.width > 0, image.height > 0 else { throw EmbeddingError.invalidImage("empty image") }
        let (th, tw) = targetSize(height: image.height, width: image.width, budget: budget)
        return (th / patchSize) * (tw / patchSize) / (poolingKernel * poolingKernel)
    }
}

extension CoreMLEmbedder: ModelPreparable {
    /// `prepare(includeVision: true)` と同じ（計測値を捨てる）。`ModelPreparable` として他のモデルと同じ手順で温めるため。
    /// 計測値が要るときやテキスト塔だけ温めたいときは `prepare(includeVision:)` を明示して呼ぶ。
    public func prepare() async throws {
        _ = try await prepare(includeVision: true)
    }
}
