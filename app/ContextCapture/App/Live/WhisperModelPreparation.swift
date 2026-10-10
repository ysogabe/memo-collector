import CCCore
import CCModels
import CCSTT
import Foundation

/// モデル準備の本物（M1 は Whisper だけ。M2 で d1・EmbeddingGemma を足す）。
///
/// 1. `WhisperModelPreparer.verify(level: .size)` で揃っているかを見る（起動時にも呼ぶので sha256 は読まない）
/// 2. 無い・食い違う → `prepare(progress:)`（Hub から約 1.5GB。sha256 まで検証して manifest を書く）
///    - **ファイルは揃っているが manifest が無い（`.unmanifested`）ときは取りに行かない**。開発中に `CC_MODELS_DIR` で
///      スパイクの取得物（読み取り専用・manifest なし）を指したとき、そこへ書き込まず、1.5GB を取り直さないため
/// 3. **アプリのプロセス内で** `WhisperKitTranscriber.prepare()`（初回は ANE 特殊化で数十秒〜1 分。キャッシュは実行バイナリ単位）
///
/// `transcriber` は AppCoordinator と同じインスタンス（読み込みは 1 回だけ。読み込み中の呼び出しは同じ読み込みを待つ）。
struct WhisperModelPreparation: ModelPreparationProviding {
    let preparer: WhisperModelPreparer
    let transcriber: WhisperKitTranscriber
    /// 進捗表示用のおおよその大きさ（large-v3-turbo の Core ML 版 + トークナイザ。実測 1.5GB）。
    static let estimatedBytes: Int64 = 1_600_000_000
    /// 初回の ANE 特殊化の目安（進捗バーをそれらしく進めるためだけに使う）。
    static let expectedLoadSeconds: Double = 60
    static let itemName = "文字起こしモデル"

    /// 読み込みに要るファイルが揃っているか（manifest の有無は問わない）。
    func filesPresent() -> Bool {
        switch try? preparer.verify(level: .size) {
        case .ready?, .unmanifested?: return true
        default: return false
        }
    }

    func isPrepared() async -> Bool {
        guard filesPresent() else { return false }
        return await transcriber.isLoaded
    }

    func prepare() -> AsyncThrowingStream<ModelPreparationProgress, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    try await run(c)
                    c.finish()
                } catch {
                    CCLog.models.error("model preparation failed: \(String(describing: error), privacy: .public)")
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ c: AsyncThrowingStream<ModelPreparationProgress, Error>.Continuation) async throws {
        let total = Self.estimatedBytes
        let status = (try? preparer.verify(level: .size)) ?? .missing([])
        CCLog.models.notice("whisper status: \(String(describing: status), privacy: .public) at \(preparer.root.path, privacy: .public)")
        switch status {
        case .ready, .unmanifested:
            break
        case .missing, .mismatched:
            c.yield(ModelPreparationProgress(phase: .downloading, fractionCompleted: 0, completedBytes: 0, totalBytes: total,
                                             currentItem: Self.itemName))
            _ = try await preparer.prepare { stage, fraction in
                // model が大半。tokenizer / manifest（sha256 の計算）は最後の 3%。
                let overall: Double
                switch stage {
                case "model": overall = fraction * 0.97
                case "tokenizer": overall = 0.97 + fraction * 0.02
                default: overall = 0.99 + fraction * 0.01
                }
                c.yield(ModelPreparationProgress(phase: .downloading, fractionCompleted: overall,
                                                 completedBytes: Int64(Double(total) * overall), totalBytes: total,
                                                 currentItem: Self.itemName))
            }
        }
        try Task.checkCancellation()

        // 読み込み（ANE 特殊化）。進み具合は取れないので、目安の時間に沿って 95% まで進める。
        let start = Date()
        let ticker = Task {
            while !Task.isCancelled {
                let f = min(0.95, Date().timeIntervalSince(start) / Self.expectedLoadSeconds)
                c.yield(ModelPreparationProgress(phase: .optimizing, fractionCompleted: f, completedBytes: total, totalBytes: total,
                                                 currentItem: Self.itemName))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { ticker.cancel() }
        try await transcriber.prepare()
        CCLog.models.notice("whisper loaded in-process in \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public)s")
        ticker.cancel()
        _ = await ticker.value  // 最後の .optimizing が .finished の後に来ないように
        c.yield(ModelPreparationProgress(phase: .finished, fractionCompleted: 1, completedBytes: total, totalBytes: total))
    }
}
