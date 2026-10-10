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

        public init(
            variant: String = WhisperModelLayout.defaultVariant,
            speechGate: SpeechGate = SpeechGate(),
            vocabularyStrategy: VocabularyStrategy = [.correction],
            biasStart: Float = 1.0,
            biasContinuation: Float = 3.0,
            firstTokenLogProbThreshold: Float? = -1.5,
            audioEncoderCompute: MLComputeUnits = .cpuAndNeuralEngine,
            textDecoderCompute: MLComputeUnits = .cpuAndNeuralEngine,
            verboseLogging: Bool = false
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
        }
    }

    /// Transcript.engine に入る名前（例: "whisperkit-large-v3-turbo"）。
    public nonisolated let engine: String
    public nonisolated let layout: WhisperModelLayout
    public nonisolated let configuration: Configuration

    /// WhisperKit は Sendable でないので箱に入れて actor の外（読み込み Task）から受け取る。
    /// 中身に触るのはこの actor の中だけ（呼び出しは actor が直列化する）。
    final class KitBox: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    private var whisperKit: WhisperKit?
    private var loading: Task<KitBox, Error>?
    /// unload のたびに増やす。読み込み中に unload されたら、その読み込み結果は捨てる。
    private var generation = 0
    /// 直近の読み込みにかかった秒数（計測用）。
    public private(set) var lastLoadDuration: TimeInterval?

    /// Whisper が無音・雑音に対して返しがちな定型句（結果がこれだけなら noSpeech とみなす）。
    static let hallucinations: Set<String> = [
        "ご視聴ありがとうございました", "ご視聴ありがとうございました。",
        "ありがとうございました", "ありがとうございました。",
        "おやすみなさい", "おやすみなさい。",
    ]

    public init(layout: WhisperModelLayout, configuration: Configuration = Configuration()) {
        self.layout = layout
        self.configuration = configuration
        self.engine = Self.engineName(for: layout.variant)
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

    public func prepare() async throws {
        _ = try await loadedKit()
    }

    public func transcribe(samples: [Float], vocabulary: [String]) async throws -> Transcript {
        if let reason = configuration.speechGate.rejectionReason(for: samples) {
            throw STTError.noSpeech(reason: reason)
        }
        let kit = try await loadedKit()
        let terms = vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let strategy = configuration.vocabularyStrategy

        var options = Self.baseDecodingOptions()
        options.firstTokenLogProbThreshold = configuration.firstTokenLogProbThreshold
        if strategy.contains(.prompt), !terms.isEmpty, let tokenizer = kit.tokenizer {
            options.promptTokens = Self.promptTokens(for: terms, tokenizer: tokenizer)
        }
        // logitsFilters は WhisperKit インスタンスに 1 つだけ持てる。actor で直列化しているので呼ぶたびに差し替える。
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
        var text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if strategy.contains(.correction), !terms.isEmpty {
            text = VocabularyCorrector(vocabulary: terms).apply(to: text)
        }
        if text.isEmpty || Self.hallucinations.contains(text) {
            throw STTError.noSpeech(reason: .emptyResult)
        }
        return Transcript(text: text, engine: engine)
    }

    // MARK: - ModelUnloadable

    public func unload() async {
        generation += 1
        loading?.cancel()
        loading = nil
        if let kit = whisperKit {
            await kit.unloadModels()
        }
        whisperKit = nil
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
        let kit = try await loadedKit()
        var options = Self.baseDecodingOptions()
        options.promptTokens = promptTokens
        kit.textDecoder.logitsFilters = nil
        return try await kit.transcribe(audioArray: samples, decodeOptions: options)
    }

    // MARK: - 内部

    private func loadedKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        if let loading { return try await loading.value.kit }
        let layout = self.layout
        let configuration = self.configuration
        let task = Task { () throws -> KitBox in
            KitBox(try await Self.load(layout: layout, configuration: configuration))
        }
        loading = task
        let myGeneration = generation
        let start = Date()
        do {
            let kit = try await task.value.kit
            guard generation == myGeneration else {
                // 読み込み中に unload された
                await kit.unloadModels()
                throw CancellationError()
            }
            whisperKit = kit
            lastLoadDuration = Date().timeIntervalSince(start)
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
