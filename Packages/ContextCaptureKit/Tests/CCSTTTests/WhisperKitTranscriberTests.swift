import CCCore
import XCTest
@testable import CCSTT

/// モデル無しで回る単体テスト。
final class WhisperKitTranscriberTests: XCTestCase {
    var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ccstt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testEngineNames() {
        XCTAssertEqual(WhisperKitTranscriber.engineName(for: "openai_whisper-large-v3-v20240930"), "whisperkit-large-v3-turbo")
        XCTAssertEqual(WhisperKitTranscriber.engineName(for: "openai_whisper-small"), "whisperkit-small")
        XCTAssertEqual(WhisperKitTranscriber.engineName(for: "distil-whisper_distil-large-v3"), "whisperkit-distil-whisper_distil-large-v3")
        let t = WhisperKitTranscriber(paths: CCPaths(dataRoot: tempRoot, modelsRoot: tempRoot))
        XCTAssertEqual(t.engine, "whisperkit-large-v3-turbo")
    }

    func testLayoutUsesCCPathsWhisperDirectory() {
        let paths = CCPaths(dataRoot: tempRoot, modelsRoot: tempRoot.appendingPathComponent("Models"))
        let layout = WhisperModelLayout(paths: paths)
        XCTAssertEqual(layout.root, paths.modelDirectory(.whisper))
        XCTAssertEqual(layout.root.lastPathComponent, "whisperkit")
        XCTAssertTrue(layout.modelFolder.path.hasSuffix("whisperkit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930"))
        XCTAssertTrue(layout.tokenizerFolder.path.hasSuffix("whisperkit/models/openai/whisper-large-v3"))
        XCTAssertEqual(layout.missingFiles(), ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "tokenizer.json"])
    }

    func testSilenceIsRejectedBeforeLoadingModel() async throws {
        // モデルが無い場所を指していても、無音・短すぎは WhisperKit に渡す前に noSpeech になる
        let t = WhisperKitTranscriber(paths: CCPaths(dataRoot: tempRoot, modelsRoot: tempRoot))
        do {
            _ = try await t.transcribe(samples: Array(repeating: 0, count: 16_000 * 2), vocabulary: [])
            XCTFail("throw されるはず")
        } catch let error as STTError {
            XCTAssertEqual(error, .noSpeech(reason: .silent))
        }
        do {
            _ = try await t.transcribe(samples: Array(repeating: 0.2, count: 4_000), vocabulary: ["Hermes"])
            XCTFail("throw されるはず")
        } catch let error as STTError {
            XCTAssertEqual(error, .noSpeech(reason: .tooShort))
        }
        let loaded = await t.isLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(STTError.noSpeech(reason: .silent).localizedDescription, "声が入っていませんでした")
    }

    func testPrepareWithoutModelThrowsModelNotFound() async {
        let t = WhisperKitTranscriber(paths: CCPaths(dataRoot: tempRoot, modelsRoot: tempRoot))
        do {
            try await t.prepare()
            XCTFail("throw されるはず")
        } catch STTError.modelNotFound(let path) {
            XCTAssertTrue(path.contains("whisperkit"), path)
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func testDecodingOptionsAreJapaneseGreedy() {
        let o = WhisperKitTranscriber.baseDecodingOptions()
        XCTAssertEqual(o.language, "ja")
        XCTAssertEqual(o.temperature, 0)
        XCTAssertFalse(o.detectLanguage)
        XCTAssertTrue(o.usePrefillPrompt)
        XCTAssertTrue(o.withoutTimestamps)
        XCTAssertNil(o.promptTokens)
    }

    func testCERMatchesPythonDefinition() {
        // poc/scripts/common.py の cer() で計算した値
        XCTAssertEqual(STTTestSupport.cer(ref: "これHermesのアダプタ。", hyp: "これHRMESのアダプタ、"), 1.0 / 13.0, accuracy: 1e-9)
        XCTAssertEqual(STTTestSupport.cer(ref: "テスト", hyp: "テスト。"), 0)
        XCTAssertEqual(STTTestSupport.cer(ref: "Claude Code", hyp: "CLAUDE CODE"), 0)
        XCTAssertEqual(STTTestSupport.cer(ref: "", hyp: "あ"), 1)
        XCTAssertEqual(STTTestSupport.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9), 9)
        XCTAssertEqual(STTTestSupport.percentile([1, 2, 3, 4], 0.5), 3) // round(1.5) = 2（偶数丸め）
    }

    // MARK: - 推論の直列化（モデル無し。推論を差し替える）

    /// 推論区間の出入りを記録する（同時に入っている数の最大値を見る）。
    actor InferenceProbe {
        private(set) var active = 0
        private(set) var maxActive = 0
        private(set) var order: [String] = []
        func enter(_ tag: String) { active += 1; maxActive = max(maxActive, active); order.append("in:" + tag) }
        func leave(_ tag: String) { active -= 1; order.append("out:" + tag) }
    }

    /// 声として通る 1 秒の合成音。先頭の値で呼び出しを見分ける。
    private func speech(tag: Float) -> [Float] {
        var s = (0..<16_000).map { i in 0.2 * Float(sin(2 * Double.pi * 440 * Double(i) / 16_000)) }
        s[0] = tag
        return s
    }

    private func makeTranscriber(_ inference: @escaping @Sendable ([Float]) async throws -> String) -> WhisperKitTranscriber {
        WhisperKitTranscriber(
            layout: WhisperModelLayout(paths: CCPaths(dataRoot: tempRoot, modelsRoot: tempRoot)),
            inferenceOverride: inference
        )
    }

    func testConcurrentTranscribeCallsDoNotOverlap() async throws {
        let probe = InferenceProbe()
        let t = makeTranscriber { samples in
            let tag = samples[0] > 0.25 ? "B" : "A"
            await probe.enter(tag)
            // 推論中に actor が再入できるよう、実際に中断する
            try await Task.sleep(nanoseconds: 150_000_000)
            await probe.leave(tag)
            return "結果\(tag)"
        }
        async let a = t.transcribe(samples: speech(tag: 0.21), vocabulary: [])
        try await Task.sleep(nanoseconds: 20_000_000)
        async let b = t.transcribe(samples: speech(tag: 0.3), vocabulary: [])
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(ra.text, "結果A")
        XCTAssertEqual(rb.text, "結果B")
        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 1, "推論区間が重なった")
        let order = await probe.order
        XCTAssertEqual(order, ["in:A", "out:A", "in:B", "out:B"])
    }

    func testManyConcurrentCallsStaySerialAndFailuresDoNotBlockTheChain() async throws {
        let probe = InferenceProbe()
        struct Boom: Error {}
        let t = makeTranscriber { samples in
            await probe.enter("x")
            try await Task.sleep(nanoseconds: 20_000_000)
            await probe.leave("x")
            if samples[0] > 0.25 { throw Boom() }
            return "ok"
        }
        // 半分は推論が throw する。throw しても次の推論が詰まらないこと
        let results = await withTaskGroup(of: Result<String, Error>.self) { group in
            for i in 0..<8 {
                let samples = speech(tag: i.isMultiple(of: 2) ? 0.21 : 0.3)
                group.addTask {
                    do { return .success(try await t.transcribe(samples: samples, vocabulary: []).text) }
                    catch { return .failure(error) }
                }
            }
            var all: [Result<String, Error>] = []
            for await r in group { all.append(r) }
            return all
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(results.filter { (try? $0.get()) == "ok" }.count, 4)
        for case .failure(let error) in results {
            guard case STTError.engineFailure = error else { return XCTFail("engineFailure になるはず: \(error)") }
        }
        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 1)
    }

    func testCancelledWaiterDoesNotBlockTheChain() async throws {
        let probe = InferenceProbe()
        let t = makeTranscriber { _ in
            await probe.enter("x")
            try? await Task.sleep(nanoseconds: 100_000_000)
            await probe.leave("x")
            return "ok"
        }
        let first = Task { try await t.transcribe(samples: speech(tag: 0.21), vocabulary: []) }
        try await Task.sleep(nanoseconds: 20_000_000)
        // 2 件目は順番を待っている間にキャンセルされる → 推論せずに CancellationError で抜ける
        let second = Task { try await t.transcribe(samples: speech(tag: 0.21), vocabulary: []) }
        try await Task.sleep(nanoseconds: 20_000_000)
        second.cancel()
        let firstText = try await first.value.text
        XCTAssertEqual(firstText, "ok")
        do {
            _ = try await second.value
            XCTFail("キャンセルされるはず")
        } catch is CancellationError {
        }
        // 3 件目はふつうに通る（門が開いたまま詰まっていない）
        let third = try await t.transcribe(samples: speech(tag: 0.21), vocabulary: [])
        XCTAssertEqual(third.text, "ok")
        let order = await probe.order
        XCTAssertEqual(order, ["in:x", "out:x", "in:x", "out:x"], "キャンセルされた 2 件目は推論しない")
    }

    func testUnloadWaitsForInFlightInference() async throws {
        let probe = InferenceProbe()
        let t = makeTranscriber { _ in
            await probe.enter("x")
            try await Task.sleep(nanoseconds: 150_000_000)
            await probe.leave("x")
            return "ok"
        }
        let running = Task { try await t.transcribe(samples: speech(tag: 0.21), vocabulary: []) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await t.unload()
        // unload は推論の終わりを待ってから戻る
        let active = await probe.active
        XCTAssertEqual(active, 0)
        let order = await probe.order
        XCTAssertEqual(order, ["in:x", "out:x"])
        let text = try await running.value.text
        XCTAssertEqual(text, "ok")
    }
}
