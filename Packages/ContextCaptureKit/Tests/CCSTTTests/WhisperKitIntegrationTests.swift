import CCCore
import CoreML
import Foundation
import XCTest
@testable import CCSTT

/// モデルがあるときだけ走る結合テスト（無ければ XCTSkip）。
///
/// モデルの場所: `CC_MODELS_DIR`（`<dir>/whisperkit/` または `<dir>/stt/whisperkit/`）→ 既定の保存先 →
/// スパイクの `spikes/runtime/models/stt/whisperkit/`（worktree なら本体の作業ツリー側）の順に探す。
///
/// 計測結果は `$TMPDIR/ccstt-*.json`（`CC_STT_RESULTS_DIR` で変更可）に書き、標準出力にも要約を出す。
final class WhisperKitIntegrationTests: XCTestCase {
    struct Row: Codable {
        var id: Int
        var ref: String
        var hyp: String
        var cer: Double
        var latencies: [Double]
        var medianLatency: Double
    }

    struct Summary: Codable {
        var label: String
        var startedAt: String
        var finishedAt: String
        var meanCER: Double
        var p50: Double
        var p90: Double
        var rows: [Row]
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func resultsDir() -> URL {
        if let d = ProcessInfo.processInfo.environment["CC_STT_RESULTS_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    func requireModel() throws -> WhisperModelLayout {
        guard let layout = STTTestSupport.locateModel() else {
            throw XCTSkip("WhisperKit のモデルが見つからない（CC_MODELS_DIR か spikes/runtime/models/stt/whisperkit を用意する）")
        }
        return layout
    }

    /// fixtures 30 件を `rounds` 周して、1 周目の仮説と各ファイルのレイテンシ中央値を返す。
    func run(_ t: WhisperKitTranscriber, vocabulary: [String], rounds: Int, label: String) async throws -> Summary {
        let captures = try STTTestSupport.loadCaptures()
        let audios = try captures.map { try STTTestSupport.loadWav(STTTestSupport.audioURL(id: $0.id)) }
        let started = Self.iso.string(from: Date())
        var hyps = Array(repeating: "", count: captures.count)
        var lats = Array(repeating: [Double](), count: captures.count)
        for round in 0..<rounds {
            for (i, audio) in audios.enumerated() {
                let t0 = Date()
                let hyp: String
                do {
                    hyp = try await t.transcribe(samples: audio, vocabulary: vocabulary).text
                } catch STTError.noSpeech {
                    hyp = ""
                }
                lats[i].append(Date().timeIntervalSince(t0))
                if round == 0 { hyps[i] = hyp }
            }
        }
        let rows = captures.enumerated().map { i, c in
            Row(id: c.id, ref: c.text, hyp: hyps[i], cer: STTTestSupport.cer(ref: c.text, hyp: hyps[i]),
                latencies: lats[i], medianLatency: lats[i].sorted()[lats[i].count / 2])
        }
        let med = rows.map(\.medianLatency)
        let summary = Summary(
            label: label, startedAt: started, finishedAt: Self.iso.string(from: Date()),
            meanCER: rows.map(\.cer).reduce(0, +) / Double(rows.count),
            p50: STTTestSupport.percentile(med, 0.5), p90: STTTestSupport.percentile(med, 0.9), rows: rows
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = resultsDir().appendingPathComponent("ccstt-\(label).json")
        try enc.encode(summary).write(to: url)
        print(String(format: "[ccstt] %@ meanCER=%.4f p50=%.3fs p90=%.3fs (%@ – %@) → %@",
                     label, summary.meanCER, summary.p50, summary.p90, started, summary.finishedAt, url.path))
        return summary
    }

    /// 受け入れ条件: 平均 CER ≤ 9%、p90 ≤ 1.8 秒（3 周の各ファイル中央値）。既定設定・PoC の語彙で測る。
    func testFixturesMeetCERAndLatencyTargets() async throws {
        let layout = try requireModel()
        print("[ccstt] model: \(layout.modelFolder.path)")
        let rss0 = STTTestSupport.residentMB()
        let t = WhisperKitTranscriber(layout: layout)

        let loadStart = Date()
        try await t.prepare()
        let load1 = Date().timeIntervalSince(loadStart)
        try await t.prepare() // 2 回目は何もしない
        let loaded = await t.isLoaded
        XCTAssertTrue(loaded)

        // ウォームアップ（初回推論のグラフ構築を計測から外す）
        let warm = try STTTestSupport.loadWav(STTTestSupport.audioURL(id: 1))
        let first = try await t.transcribe(samples: warm, vocabulary: [])
        XCTAssertEqual(first.engine, "whisperkit-large-v3-turbo")
        XCTAssertFalse(first.text.hasPrefix(" "))

        let withVocab = try await run(t, vocabulary: STTTestSupport.pocVocabulary, rounds: 3, label: "default-vocab")
        let plain = try await run(t, vocabulary: [], rounds: 1, label: "default-novocab")
        let rss1 = STTTestSupport.residentMB()

        // unload → 再ロード（2 回目ロード時間。OS の特殊化キャッシュが効く）
        await t.unload()
        let unloaded = await t.isLoaded
        XCTAssertFalse(unloaded)
        let reloadStart = Date()
        try await t.prepare()
        let load2 = Date().timeIntervalSince(reloadStart)

        print(String(format: "[ccstt] load1=%.1fs load2=%.1fs rss_before=%.0fMB rss_after=%.0fMB", load1, load2, rss0, rss1))
        print(String(format: "[ccstt] CER vocab=%.4f novocab=%.4f p50=%.3f p90=%.3f", withVocab.meanCER, plain.meanCER, withVocab.p50, withVocab.p90))

        XCTAssertLessThanOrEqual(withVocab.meanCER, 0.09)
        XCTAssertLessThanOrEqual(plain.meanCER, 0.09)
        XCTAssertLessThanOrEqual(withVocab.p90, 1.8)
        // 語彙の後処理で悪化しないこと
        XCTAssertLessThanOrEqual(withVocab.meanCER, plain.meanCER + 1e-9)
    }

    /// 合成した無音・雑音は（モデルを読んだ状態でも）WhisperKit に渡らず noSpeech。
    func testSilenceWithLoadedModelIsNoSpeech() async throws {
        let layout = try requireModel()
        let t = WhisperKitTranscriber(layout: layout)
        try await t.prepare()
        for samples in [[Float](repeating: 0, count: 32_000), [Float](repeating: 0.001, count: 32_000)] {
            do {
                _ = try await t.transcribe(samples: samples, vocabulary: [])
                XCTFail("noSpeech になるはず")
            } catch let e as STTError {
                XCTAssertEqual(e, .noSpeech(reason: .silent))
            }
        }
    }

    /// 語彙の効き方の調査（`CC_STT_EXPERIMENT=1` のときだけ走る。1 周・数分）。
    func testVocabularyStrategiesExperiment() async throws {
        guard ProcessInfo.processInfo.environment["CC_STT_EXPERIMENT"] == "1" else {
            throw XCTSkip("CC_STT_EXPERIMENT=1 のときだけ走る調査用テスト")
        }
        let layout = try requireModel()
        typealias Strategy = WhisperKitTranscriber.VocabularyStrategy
        let vocab = STTTestSupport.pocVocabulary
        let english = ["This is an English transcript. Please write everything in English words."]
        // (ラベル, 方式, 語彙, 語頭バイアス, 続きバイアス, firstTokenLogProbThreshold)
        let cases: [(String, Strategy, [String], Float, Float, Float?)] = [
            ("x-plain", [], [], 0, 0, -1.5),
            ("x-prompt", [.prompt], vocab, 0, 0, -1.5),
            ("x-prompt-nofirst", [.prompt], vocab, 0, 0, nil),
            // 前文脈が効いているかの対照: 出力を英語寄りに引っ張るはずの強い前文脈
            ("x-prompt-english", [.prompt], english, 0, 0, nil),
            ("x-bias-1-3", [.logitBias], vocab, 1, 3, -1.5),
            ("x-bias-2-5", [.logitBias], vocab, 2, 5, -1.5),
            ("x-correction", [.correction], vocab, 0, 0, -1.5),
            ("x-prompt-nofirst-correction", [.prompt, .correction], vocab, 0, 0, nil),
            ("x-bias-1-3-correction", [.logitBias, .correction], vocab, 1, 3, -1.5),
        ]
        var baseline: [String] = []
        // 1 つの WhisperKit を使い回すと設定を変えられないので、方式ごとに作り直す（2 回目以降のロードは数秒）
        for (label, strategy, vocabulary, b0, b1, firstTh) in cases {
            let t = WhisperKitTranscriber(layout: layout, configuration: .init(
                vocabularyStrategy: strategy, biasStart: b0, biasContinuation: b1, firstTokenLogProbThreshold: firstTh))
            try await t.prepare()
            let s = try await run(t, vocabulary: vocabulary, rounds: 1, label: label)
            let hyps = s.rows.map(\.hyp)
            if baseline.isEmpty { baseline = hyps }
            let changed = zip(baseline, hyps).filter { $0 != $1 }.count
            print("[ccstt] \(label): changed vs plain = \(changed)/30")
            await t.unload()
        }
    }

    /// エンコーダ / デコーダの載せ先ごとの所要時間（`CC_STT_EXPERIMENT=compute`）。
    func testComputeUnitsExperiment() async throws {
        guard ProcessInfo.processInfo.environment["CC_STT_EXPERIMENT"] == "compute" else {
            throw XCTSkip("CC_STT_EXPERIMENT=compute のときだけ走る調査用テスト")
        }
        let layout = try requireModel()
        let audio = try STTTestSupport.loadWav(STTTestSupport.audioURL(id: 2))
        let cases: [(String, MLComputeUnits, MLComputeUnits)] = [
            ("enc-ane/dec-ane", .cpuAndNeuralEngine, .cpuAndNeuralEngine),
            ("enc-gpu/dec-ane", .cpuAndGPU, .cpuAndNeuralEngine),
            ("enc-ane/dec-ane(again)", .cpuAndNeuralEngine, .cpuAndNeuralEngine),
        ]
        for (label, enc, dec) in cases {
            let t = WhisperKitTranscriber(layout: layout, configuration: .init(audioEncoderCompute: enc, textDecoderCompute: dec))
            let l0 = Date()
            try await t.prepare()
            let load = Date().timeIntervalSince(l0)
            var lines: [String] = []
            for _ in 0..<6 {
                let t0 = Date()
                let r = try await t.debugTranscribe(samples: audio, promptTokens: nil)
                let wall = Date().timeIntervalSince(t0)
                lines.append(String(format: "%.2f(enc %.2f)", wall, r.first?.timings.encoding ?? -1))
            }
            print("[ccstt] compute \(label) load=\(String(format: "%.1f", load))s: \(lines.joined(separator: " "))")
            await t.unload()
        }
    }

    /// 前文脈トークンが実際にプレフィルへ入っているかをログで確かめる（`CC_STT_EXPERIMENT=prefill`）。
    func testPrefillLogExperiment() async throws {
        guard ProcessInfo.processInfo.environment["CC_STT_EXPERIMENT"] == "prefill" else {
            throw XCTSkip("CC_STT_EXPERIMENT=prefill のときだけ走る調査用テスト")
        }
        let layout = try requireModel()
        let t = WhisperKitTranscriber(layout: layout)
        let tok = try await t.debugPromptTokens(STTTestSupport.pocVocabulary)
        print("[ccstt] specialTokenBegin=\(tok.specialTokenBegin)")
        print("[ccstt] raw ids (\(tok.raw.count)): \(tok.raw)")
        print("[ccstt] filtered ids (\(tok.filtered.count)): \(tok.filtered)")
        print("[ccstt] decoded: \(tok.decoded)")
        for id in [1, 6, 10] {
            let audio = try STTTestSupport.loadWav(STTTestSupport.audioURL(id: id))
            let plain = try await t.debugTranscribe(samples: audio, promptTokens: nil)
            let prompted = try await t.debugTranscribe(samples: audio, promptTokens: tok.filtered)
            let english = try await t.debugTranscribe(samples: audio, promptTokens: try await t.debugPromptTokens(
                ["This is an English transcript. Please write everything in English words."]).filtered)
            for (name, r) in [("plain", plain), ("prompt", prompted), ("english", english)] {
                let loops = r.map { $0.timings.totalDecodingLoops }.reduce(0, +)
                let toks = r.flatMap { $0.segments.flatMap(\.tokens) }
                print("[ccstt] c\(id) \(name): loops=\(loops) text=\(r.map(\.text).joined()) tokens=\(toks.prefix(40))")
            }
        }
        // 所要時間の内訳（どこに時間が掛かっているか）
        let audio = try STTTestSupport.loadWav(STTTestSupport.audioURL(id: 2))
        for _ in 0..<3 {
            let t0 = Date()
            let r = try await t.debugTranscribe(samples: audio, promptTokens: nil)
            let wall = Date().timeIntervalSince(t0)
            guard let tm = r.first?.timings else { continue }
            print(String(format: "[ccstt] timing wall=%.3f full=%.3f mel=%.3f enc=%.3f loop=%.3f pred=%.3f filt=%.3f samp=%.3f kv=%.3f nonpred=%.3f win=%.3f loops=%.0f fallbacks=%.0f",
                         wall, tm.fullPipeline, tm.logmels, tm.encoding, tm.decodingLoop, tm.decodingPredictions,
                         tm.decodingFiltering, tm.decodingSampling, tm.decodingKvCaching, tm.decodingNonPrediction,
                         tm.decodingWindowing, tm.totalDecodingLoops, tm.totalDecodingFallbacks))
        }
    }
}
