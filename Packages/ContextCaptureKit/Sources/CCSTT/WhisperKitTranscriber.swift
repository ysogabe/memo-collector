import CCCore
import CoreML
import Foundation
import WhisperKit

/// WhisperKit（Core ML / ANE）による日本語 STT。
///
/// - `prepare()` は `<models>/whisperkit/` からモデルを読む（ネットワークには出ない）。何度呼んでも読み込みは 1 回。
///   初回は ANE 特殊化で約 1 分、2 回目以降（OS のキャッシュが効く）は数秒。
/// - `transcribe` は 16kHz モノラルを受け取り、日本語固定・temperature 0 で認識する。
///   無音・0.3 秒未満は WhisperKit に渡さず `STTError.noSpeech` を投げる。
/// - 語彙は既定で「後処理の綴り寄せ」（`VocabularyCorrector`）だけを使う。fixtures 30 件（PoC と同じ語彙 7 語）で
///   平均 CER 7.72% → 6.75%（改善 4 件・悪化 0 件）。
///
/// 語彙プロンプト（promptTokens）について（2026-10-10 調査）:
/// - スパイクで「出力が 1 文字も変わらなかった」原因は WhisperKit ではなくスパイク側にある。
///   `WhisperKitConfig` に `modelFolder` を渡さないと `load` の既定が false になり、初期化直後は
///   `wk.tokenizer == nil`。そのため `if let tok = wk.tokenizer { opts.promptTokens = ... }` が黙って飛ばされ、
///   プロンプトは一度も渡っていなかった（モデルは最初の transcribe で遅延ロードされる）。
/// - 正しく渡すと効く（英語の前文脈で 21/30 件の出力が英語化する）が、語彙プロンプトは CER を悪化させた
///   （11.2%。うち 1 件は最初のトークンの確信度が `firstTokenLogProbThreshold` を下回って空文字になる。
///   閾値を外しても 8.4%、後処理と併用しても 7.5%）。句読点の付け方が変わる副作用が大きい。
/// - logit バイアス（語頭 +1 / 続き +3）は 7.31%、後処理と併用で 6.75%（後処理のみと同じ）。+2 / +5 では
///   語彙に無い "Capture" を作るなどして 8.13% に悪化。効果が後処理と重なるため既定では使わない。
/// どちらも `VocabularyStrategy` で選べる（調査用テスト: WhisperKitIntegrationTests.testVocabularyStrategiesExperiment）。
public actor WhisperKitTranscriber: SpeechTranscribing, ModelUnloadable {
    /// 語彙の使い方。
    public struct VocabularyStrategy: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// `<|startofprev|>` + 語彙を前文脈として与える（Whisper の initial_prompt と同じ）。
        public static let prompt = VocabularyStrategy(rawValue: 1 << 0)
        /// 語彙の綴りのトークン列に logit を加算する。
        public static let logitBias = VocabularyStrategy(rawValue: 1 << 1)
        /// 認識後に英字部分を語彙の綴りへ寄せる。
        public static let correction = VocabularyStrategy(rawValue: 1 << 2)
    }

    public struct Configuration: Sendable {
        public var variant: String
        public var speechGate: SpeechGate
        public var vocabularyStrategy: VocabularyStrategy
        /// `.logitBias` の語頭・語の続きへの加算量。
        public var biasStart: Float
        public var biasContinuation: Float
        /// 最初のトークンの対数確率がこれ未満なら、その窓を打ち切る（WhisperKit の既定 -1.5。nil で無効）。
        /// 前文脈（`.prompt`）を付けると最初のトークンの確信度が下がり、これに引っかかって空文字になることがある。
        public var firstTokenLogProbThreshold: Float?
        /// 音声エンコーダ（処理時間の大半）を載せる先。既定は ANE（GPU を d1 / 埋め込みの MLX と取り合わない）。
        public var audioEncoderCompute: MLComputeUnits
        /// テキストデコーダを載せる先。
        public var textDecoderCompute: MLComputeUnits
        /// WhisperKit のログを出すか（調査用）。
        public var verboseLogging: Bool
        /// 読み込みの直後に短い合成音で 1 回推論して温めるか（`warmUpSamples`）。
        /// 温めないと、読み込み後の最初の文字起こしが 5.2〜8.4 秒かかる（2 回目以降は 1.6 秒前後。docs/e2e/report.md §6・§7 問題 3）。
        public var warmUpAfterLoad: Bool
        /// 品質（圧縮率・平均対数確率）が足りないときに温度を上げて解き直す最大回数（WhisperKit の既定 5、増分 0.2）。
        /// 解き直すたびにデコーダのループを最初からやり直すので、そのぶん遅くなる。
        public var temperatureFallbackCount: Int

        public init(
            variant: String = WhisperModelLayout.defaultVariant,
            speechGate: SpeechGate = SpeechGate(),
            vocabularyStrategy: VocabularyStrategy = [.correction],
            biasStart: Float = 1.0,
            biasContinuation: Float = 3.0,
            firstTokenLogProbThreshold: Float? = -1.5,
            audioEncoderCompute: MLComputeUnits = .cpuAndNeuralEngine,
            textDecoderCompute: MLComputeUnits = .cpuAndNeuralEngine,
            verboseLogging: Bool = false,
            warmUpAfterLoad: Bool = true,
            temperatureFallbackCount: Int = 5
        ) {
            self.variant = variant
            self.speechGate = speechGate
            self.vocabularyStrategy = vocabularyStrategy
            self.biasStart = biasStart
            self.biasContinuation = biasContinuation
            self.firstTokenLogProbThreshold = firstTokenLogProbThreshold
            self.audioEncoderCompute = audioEncoderCompute
            self.textDecoderCompute = textDecoderCompute
            self.verboseLogging = verboseLogging
            self.warmUpAfterLoad = warmUpAfterLoad
            self.temperatureFallbackCount = temperatureFallbackCount
        }
    }

    /// Transcript.engine に入る名前（例: "whisperkit-large-v3-turbo"）。
    public nonisolated let engine: String
    public nonisolated let layout: WhisperModelLayout
    public nonisolated let configuration: Configuration

    /// WhisperKit は Sendable でないので箱に入れて actor の外（読み込み Task）から受け取る。
    /// 中身に触るのはこの actor の中だけ。⚠️ actor は await で再入するので、推論の直列化は actor ではなく
    /// `inferenceGate`（`acquireInferenceGate` / `releaseInferenceGate`）が担う。
    final class KitBox: @unchecked Sendable {
        let kit: WhisperKit
        /// 温めにかかった秒数と失敗（読み込み Task の中で書き、完了後に actor が読む）。
        var warmUpDuration: TimeInterval?
        var warmUpError: String?
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    private var whisperKit: WhisperKit?
    private var loading: Task<KitBox, Error>?
    /// unload のたびに増やす。読み込み中に unload されたら、その読み込み結果は捨てる。
    private var generation = 0
    /// 直近の読み込みにかかった秒数（計測用。温めの時間を含む）。
    public private(set) var lastLoadDuration: TimeInterval?
    /// 直近の読み込みのうち、温め（`Configuration.warmUpAfterLoad`）にかかった秒数。温めていなければ nil。
    public private(set) var lastWarmUpDuration: TimeInterval?
    /// 直近の温めが失敗したときの説明（型名だけ。成功・温めていなければ nil）。
    public private(set) var lastWarmUpError: String?

    /// Whisper が無音・雑音に対して返しがちな定型句（結果がこれだけなら noSpeech とみなす）。
    static let hallucinations: Set<String> = [
        "ご視聴ありがとうございました", "ご視聴ありがとうございました。",
        "ありがとうございました", "ありがとうございました。",
        "おやすみなさい", "おやすみなさい。",
    ]

    public init(layout: WhisperModelLayout, configuration: Configuration = Configuration()) {
        self.init(layout: layout, configuration: configuration, inferenceOverride: nil)
    }

    /// テスト用: 推論を差し替える（`inferenceOverride` は 16kHz のサンプルを受け取り、認識結果の文字列を返す）。
    init(
        layout: WhisperModelLayout,
        configuration: Configuration = Configuration(),
        inferenceOverride: (@Sendable ([Float]) async throws -> String)?
    ) {
        self.layout = layout
        self.configuration = configuration
        self.engine = Self.engineName(for: layout.variant)
        self.inferenceOverride = inferenceOverride
    }

    /// 既定の保存先（`CCPaths.resolve()`）のモデルを使う。
    public init(paths: CCPaths = .resolve(), configuration: Configuration = Configuration()) {
        self.init(layout: WhisperModelLayout(paths: paths, variant: configuration.variant), configuration: configuration)
    }

    /// variant 名から engine 名を作る。既知の variant は通称（turbo）にする。
    public static func engineName(for variant: String) -> String {
        switch variant {
        case "openai_whisper-large-v3-v20240930": return "whisperkit-large-v3-turbo"
        case "openai_whisper-large-v3-v20240930_turbo": return "whisperkit-large-v3-turbo-ane"
        default:
            let short = variant.hasPrefix("openai_whisper-") ? String(variant.dropFirst("openai_whisper-".count)) : variant
            return "whisperkit-\(short)"
        }
    }

    // MARK: - SpeechTranscribing

    /// 読み込み、`Configuration.warmUpAfterLoad` なら 1 回推論して温める（温めの失敗は無視する）。
    /// 温めは読み込みと同じ Task の中で済ませてから WhisperKit を公開する。その間に届いた `transcribe` は
    /// 読み込みの完了（= 温めの完了）を待ってから普通に処理する（同じ WhisperKit を 2 つの推論が同時に触らない）。
    /// 温めるのは `prepare()` から読み込んだときだけ。`transcribe` が初めての読み込みを始めたとき（prepare が走っていない・失敗した）は
    /// 温めない（ユーザーの文字起こしの前に温めの推論を挟まない）。
    public func prepare() async throws {
        _ = try await loadedKit(warmUp: configuration.warmUpAfterLoad)
    }

    public func transcribe(samples: [Float], vocabulary: [String]) async throws -> Transcript {
        if let reason = configuration.speechGate.rejectionReason(for: samples) {
            throw STTError.noSpeech(reason: reason)
        }
        let terms = vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let strategy = configuration.vocabularyStrategy

        // ⚠️ actor は `await` のたびに再入する。`kit.transcribe` を待つ間に次の `transcribe` が入ってくると、
        // 同じ WhisperKit で 2 つの推論が並行して走り、インスタンスに 1 つしかない `textDecoder.logitsFilters` も
        // 途中で上書きされる。actor だけでは直列化されないので、推論区間を `inferenceGate` で 1 本ずつにする。
        // 読み込みは門の外で先に待つ（読み込み中の `unload()` が門で待たされず、すぐ読み込みを打ち切れるように）。
        let waitStart = Date()
        if inferenceOverride == nil { _ = try await loadedKit() }
        await acquireInferenceGate()
        defer { releaseInferenceGate() }
        try Task.checkCancellation()

        var text: String
        var diagnostics: TranscriptDiagnostics?
        if let inferenceOverride {
            do {
                text = try await inferenceOverride(samples)
            } catch {
                throw STTError.engineFailure(String(describing: error))
            }
        } else {
            // 門を待つ間に unload されていれば読み込み直す（ふつうは読み込み済みなのですぐ返る）
            let kit = try await loadedKit()
            let waitSeconds = Date().timeIntervalSince(waitStart)
            var options = Self.baseDecodingOptions()
            options.firstTokenLogProbThreshold = configuration.firstTokenLogProbThreshold
            options.temperatureFallbackCount = max(0, configuration.temperatureFallbackCount)
            if strategy.contains(.prompt), !terms.isEmpty, let tokenizer = kit.tokenizer {
                options.promptTokens = Self.promptTokens(for: terms, tokenizer: tokenizer)
            }
            // logitsFilters は WhisperKit インスタンスに 1 つだけ持てる。推論区間は inferenceGate で 1 本ずつなので、
            // 呼ぶたびに差し替えても他の推論の途中で書き換わることはない。
            if strategy.contains(.logitBias), !terms.isEmpty, let tokenizer = kit.tokenizer {
                kit.textDecoder.logitsFilters = [Self.biasFilter(for: terms, tokenizer: tokenizer, configuration: configuration)]
            } else {
                kit.textDecoder.logitsFilters = nil
            }
            let results: [TranscriptionResult]
            do {
                results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            } catch {
                throw STTError.engineFailure(String(describing: error))
            }
            text = results.map(\.text).joined()
            diagnostics = Self.diagnostics(
                for: results, audioSeconds: Double(samples.count) / 16_000, waitSeconds: waitSeconds,
                temperatureIncrement: Double(options.temperatureIncrementOnFallback)
            )
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if strategy.contains(.correction), !terms.isEmpty {
            text = VocabularyCorrector(vocabulary: terms).apply(to: text)
        }
        if text.isEmpty || Self.hallucinations.contains(text) {
            throw STTError.noSpeech(reason: .emptyResult)
        }
        return Transcript(text: text, engine: engine, diagnostics: diagnostics)
    }

    // MARK: - ModelUnloadable

    /// 読み込み中なら打ち切る（その読み込みを待っている `transcribe` は `CancellationError`）。
    /// 推論の途中なら、その推論が終わるのを待ってから解放する（推論中の WhisperKit を解放しない）。
    /// 解放の前に並んでいた `transcribe` は先に処理され、後から来たものは解放後に読み込み直す。
    public func unload() async {
        generation += 1
        loading?.cancel()
        loading = nil
        await acquireInferenceGate()
        defer { releaseInferenceGate() }
        if let kit = whisperKit {
            whisperKit = nil
            await kit.unloadModels()
        }
    }

    public var isLoaded: Bool { whisperKit != nil }

    // MARK: - 調査用（テストから @testable で使う）

    /// 語彙を前文脈トークンにした結果（ID と、それを decode し直した文字列）。
    func debugPromptTokens(_ terms: [String]) async throws -> (raw: [Int], filtered: [Int], decoded: String, specialTokenBegin: Int) {
        let kit = try await loadedKit()
        guard let tokenizer = kit.tokenizer else { throw STTError.engineFailure("tokenizer unavailable") }
        let raw = tokenizer.encode(text: " " + terms.joined(separator: "、"))
        let filtered = Self.promptTokens(for: terms, tokenizer: tokenizer)
        return (raw, filtered, tokenizer.decode(tokens: filtered), tokenizer.specialTokens.specialTokenBegin)
    }

    /// 前文脈トークンをそのまま渡して WhisperKit の生の結果を返す。
    func debugTranscribe(samples: [Float], promptTokens: [Int]?) async throws -> [TranscriptionResult] {
        await acquireInferenceGate()
        defer { releaseInferenceGate() }
        let kit = try await loadedKit()
        var options = Self.baseDecodingOptions()
        options.promptTokens = promptTokens
        kit.textDecoder.logitsFilters = nil
        return try await kit.transcribe(audioArray: samples, decodeOptions: options)
    }

    // MARK: - 推論の直列化

    /// テスト用: WhisperKit の代わりに呼ぶ推論（モデル無しで直列化を確かめるため）。nil なら WhisperKit を使う。
    private let inferenceOverride: (@Sendable ([Float]) async throws -> String)?
    /// 推論区間（と unload）を 1 本ずつにするための門。actor の中だけで触る。
    private var inferenceBusy = false
    private var inferenceWaiters: [CheckedContinuation<Void, Never>] = []

    /// 門が空くまで待って入る（先着順）。待っている間にキャンセルされても、順番が来るまで待つ
    /// （入った直後に呼び出し側が `Task.checkCancellation()` で抜け、`releaseInferenceGate()` で次へ渡す）。
    private func acquireInferenceGate() async {
        if !inferenceBusy {
            inferenceBusy = true
            return
        }
        await withCheckedContinuation { inferenceWaiters.append($0) }
        // release が busy のまま順番を渡してくれる
    }

    /// 門を出る。待っている人がいれば busy のまま次へ渡す。throw・キャンセルでも必ず呼ばれるよう `defer` で使う。
    private func releaseInferenceGate() {
        if inferenceWaiters.isEmpty {
            inferenceBusy = false
        } else {
            inferenceWaiters.removeFirst().resume()
        }
    }

    // MARK: - 内部

    private func loadedKit(warmUp: Bool = false) async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        if let loading { return try await loading.value.kit }
        let layout = self.layout
        let configuration = self.configuration
        let task = Task { () throws -> KitBox in
            let box = KitBox(try await Self.load(layout: layout, configuration: configuration))
            if warmUp, !Task.isCancelled {
                let t0 = Date()
                box.warmUpError = await Self.warmUp(box.kit)
                box.warmUpDuration = Date().timeIntervalSince(t0)
            }
            return box
        }
        loading = task
        let myGeneration = generation
        let start = Date()
        do {
            let box = try await task.value
            let kit = box.kit
            guard generation == myGeneration else {
                // 読み込み中に unload された
                await kit.unloadModels()
                throw CancellationError()
            }
            whisperKit = kit
            lastLoadDuration = Date().timeIntervalSince(start)
            lastWarmUpDuration = box.warmUpDuration
            lastWarmUpError = box.warmUpError
            loading = nil
            return kit
        } catch {
            if generation == myGeneration { loading = nil }
            throw error
        }
    }

    static func load(layout: WhisperModelLayout, configuration: Configuration) async throws -> WhisperKit {
        let verbose = configuration.verboseLogging
        let missing = layout.missingFiles()
        guard missing.isEmpty else {
            throw STTError.modelNotFound(path: layout.modelFolder.path + " (missing: \(missing.joined(separator: ", ")))")
        }
        let config = WhisperKitConfig(
            model: layout.variant,
            downloadBase: layout.root,
            modelFolder: layout.modelFolder.path,
            // tokenizer は <root>/models/openai/whisper-large-v3/ に置く（Hub のレイアウト）。見つかるのでネットワークへは出ない
            tokenizerFolder: layout.root,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: configuration.audioEncoderCompute,
                textDecoderCompute: configuration.textDecoderCompute
            ),
            verbose: verbose,
            logLevel: verbose ? .debug : .error,
            prewarm: false,
            load: true,
            download: false
        )
        do {
            return try await WhisperKit(config)
        } catch {
            throw STTError.engineFailure(String(describing: error))
        }
    }

    /// 温めに使う合成音（2 秒・16kHz・振幅 0.05 の 440Hz 正弦波）。完全な無音より実際の入力に近い経路
    /// （エンコーダ → デコーダの数トークン）を通す。`SpeechGate` は通さずに WhisperKit へ直接渡すので、無音判定には掛からない。
    /// ⚠️ 1 秒以下だと WhisperKit は窓を 1 つも処理しない（`DecodingOptions.windowClipTime` の既定 1 秒を末尾から削るため）。
    static func warmUpSamples(sampleRate: Int = 16_000, seconds: Double = 2.0) -> [Float] {
        let n = Int(Double(sampleRate) * seconds)
        return (0..<n).map { i in 0.05 * Float(sin(2 * Double.pi * 440 * Double(i) / Double(sampleRate))) }
    }

    /// 1 回推論して、Core ML / ANE の初回実行のコストを先に払う。結果は捨てる（ログにも出さない）。失敗しても読み込みは成功扱いで、
    /// 失敗の説明（型名）を返す。
    static func warmUp(_ kit: WhisperKit) async -> String? {
        var options = baseDecodingOptions()
        // 合成音の結果は使わないので、デコーダは数トークンで打ち切る（初回実行のコストはデコーダの最初の 1 回でほぼ払える）。
        options.sampleLength = 8
        kit.textDecoder.logitsFilters = nil
        do {
            _ = try await kit.transcribe(audioArray: warmUpSamples(), decodeOptions: options)
            return nil
        } catch {
            return "\(type(of: error))"
        }
    }

    /// WhisperKit の結果から所要時間の内訳を作る（数値だけ。本文・トークンは持ち出さない）。結果が空なら nil。
    /// 窓が複数あれば時間・回数は合計、温度・圧縮率は最大、平均対数確率は最小をとる。
    static func diagnostics(
        for results: [TranscriptionResult], audioSeconds: Double, waitSeconds: Double, temperatureIncrement: Double
    ) -> TranscriptDiagnostics? {
        guard !results.isEmpty else { return nil }
        let timings = results.map(\.timings)
        func sum(_ key: KeyPath<TranscriptionTimings, Double>) -> Double { timings.map { $0[keyPath: key] }.reduce(0, +) }
        let segments = results.flatMap(\.segments)
        let temperature = Double(segments.map(\.temperature).max() ?? 0)
        let fallbacks = temperatureIncrement > 0 ? Int((temperature / temperatureIncrement).rounded()) : 0
        let firstToken: Double? = timings.first.flatMap { t in
            let d = t.firstTokenTime - t.pipelineStart
            return d.isFinite && d >= 0 && d < 3600 ? d : nil
        }
        return TranscriptDiagnostics(
            audioSeconds: audioSeconds,
            waitSeconds: waitSeconds,
            pipelineSeconds: sum(\.fullPipeline),
            logmelSeconds: sum(\.logmels),
            encodingSeconds: sum(\.encoding),
            decodingSeconds: max(0, sum(\.decodingLoop) - sum(\.encoding) - sum(\.logmels)),
            fallbackSeconds: sum(\.decodingFallback),
            fallbacks: fallbacks,
            temperature: temperature,
            decodingLoops: Int(sum(\.totalDecodingLoops)),
            windows: Int(sum(\.totalDecodingWindows)),
            firstTokenSeconds: firstToken,
            avgLogProb: segments.map(\.avgLogprob).min().map(Double.init),
            compressionRatio: segments.map(\.compressionRatio).max().map(Double.init)
        )
    }

    /// 日本語固定・temperature 0・タイムスタンプなし。
    static func baseDecodingOptions() -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: "ja",
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
    }

    /// 語彙を「、」でつないだ文を前文脈トークンにする（`<|startofprev|>` は WhisperKit が付ける）。
    /// tokenizer.encode は `<|startoftranscript|>` などを付けて返すので、特殊トークンを除く。
    static func promptTokens(for terms: [String], tokenizer: any WhisperTokenizer) -> [Int] {
        let text = " " + terms.joined(separator: "、")
        return tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }

    static func biasFilter(for terms: [String], tokenizer: any WhisperTokenizer, configuration: Configuration) -> VocabularyBiasFilter {
        let begin = tokenizer.specialTokens.specialTokenBegin
        var sequences: [[Int]] = []
        for term in terms {
            for variant in [term, " " + term] {
                let ids = tokenizer.encode(text: variant).filter { $0 < begin }
                if !ids.isEmpty, !sequences.contains(ids) { sequences.append(ids) }
            }
        }
        return VocabularyBiasFilter(
            sequences: sequences,
            startBias: configuration.biasStart,
            continuationBias: configuration.biasContinuation,
            specialTokenBegin: begin
        )
    }
}

extension WhisperKitTranscriber: ModelPreparable {}
