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
}
