import CCCore
import CCTriage
import Foundation

/// 保存〜トリアージ〜画面更新の配線（F-09 / F-10 / F-11）。`LiveServices` が 1 つ持つ。
///
/// - 保存直後（`AppCoordinator.onRecordSaved`。文字起こしに失敗して注釈が空の記録も）→ `enqueue(id:)`
/// - 文字起こしの再試行で注釈が入った（`AppCoordinator.onTranscriptRetried`）→ `annotationEdited(id:)`（意図と索引のやり直し）
/// - 注釈の編集（詳細ビュー）→ `annotationEdited(id:)`（= `reprocess(id:)`。手で変えた意図は上書きされない）
/// - `TriageQueue.events()` を購読し、ガードか意図を書いた記録が終わったら `onRecordsChanged`（= `AppModel.recordsDidChange()`）。
///   索引だけの更新は画面に出ないので知らせない（索引の作り直しで Inbox を何百回も読み直さないため）
/// - 取り消し（`onRecordRemoved`）はキューから外す API が無いが、キューは処理時に `store.get` で消えた記録を
///   `.recordMissing` で飛ばすので何もしなくてよい
/// - キャプチャ中（`AppCoordinator.onCaptureActivityChanged`）→ `captureActivityChanged(_:)` → `setCapturing`
///   （録音〜保存の間はトリアージの次のステップを始めない。Whisper と ANE を取り合わないため）
/// - 各ステップの結果は `CCLog.triage` の notice で出す（id・ステップ・成功 / スキップ理由 / 失敗の種類だけ。本文は出さない）
@MainActor
final class TriageWiring {
    let queue: any TriageQueuing
    var onRecordsChanged: @MainActor () -> Void = {}
    /// d1 を解放したとき（デバッグ表示の更新用）。
    var onClassifierUnloaded: @MainActor () -> Void = {}

    /// 処理中の記録のうち、画面に出るもの（ガード・意図）を書いたもの。
    private var visiblyChanged: Set<String> = []
    private var observer: Task<Void, Never>?
    /// キャプチャ中の通知を順に渡すための鎖（Task を別々に投げると pause / resume の到着順が入れ替わりうる）。
    private var captureActivityChain: Task<Void, Never>?

    init(queue: any TriageQueuing) {
        self.queue = queue
    }

    func recordSaved(id: String) {
        let queue = queue
        Task { await queue.enqueue(id: id) }
    }

    func annotationEdited(id: String) {
        let queue = queue
        Task { await queue.annotationEdited(id: id) }
    }

    /// キャプチャが始まった / すべて終わった（AppCoordinator が 0↔1 の切り替わりで呼ぶ）。呼ばれた順にキューへ渡す。
    func captureActivityChanged(_ active: Bool) {
        CCLog.triage.notice("\(active ? "paused" : "resumed", privacy: .public) (capture \(active ? "started" : "finished", privacy: .public))")
        let queue = queue, previous = captureActivityChain
        captureActivityChain = Task {
            await previous?.value
            await queue.setCapturing(active)
        }
    }

    /// これまでの `captureActivityChanged` がキューへ届くまで待つ（テスト用）。
    func waitForCaptureActivityForwarded() async {
        await captureActivityChain?.value
    }

    /// イベントの購読を始める（1 回だけ）。
    func observe(_ events: AsyncStream<TriageEvent>) {
        guard observer == nil else { return }
        observer = Task { [weak self] in
            for await e in events {
                self?.handle(e)
            }
        }
    }

    func handle(_ event: TriageEvent) {
        switch event {
        case let .stepFinished(id, step, outcome):
            switch outcome {
            case .succeeded:
                if step != .index { visiblyChanged.insert(id) }
                CCLog.triage.notice("\(id, privacy: .public) \(step.rawValue, privacy: .public): ok")
            case .skipped(.notReady):
                // モデルが未準備で後回し（失敗ではない）。モデルが揃った後の resumePending() で拾われる。
                CCLog.triage.notice("\(id, privacy: .public) \(step.rawValue, privacy: .public): deferred (model not ready)")
            case let .skipped(reason):
                CCLog.triage.notice("\(id, privacy: .public) \(step.rawValue, privacy: .public): skipped \(reason.rawValue, privacy: .public)")
            case let .failed(detail):
                // detail は型名とエラーコードだけ（本文・秘密を含まない。TriageQueue.describe）。
                CCLog.triage.notice("\(id, privacy: .public) \(step.rawValue, privacy: .public): failed \(detail, privacy: .public)")
            }
        case let .recordFinished(id):
            if visiblyChanged.remove(id) != nil { onRecordsChanged() }
        case .suspendedForCapture:
            CCLog.triage.info("queue waiting for capture pause to end")
        case .idle:
            CCLog.triage.info("queue idle")
        case .classifierUnloaded:
            CCLog.triage.notice("d1 unloaded after idle timeout")
            onClassifierUnloaded()
        }
    }
}

/// 詳細ビューでの手直しを、最新の記録に**そのフィールドだけ**当てる（トリアージが裏で書いたガード・意図・索引を消さない）。
enum RecordEdits {
    /// 意図を手で変える。`TriageResult.manual`（model == "user"）にするので、以後の自動推定は上書きしない。
    /// 日時言及は自動推定の値を引き継ぐ（無ければ false）。
    static func setManualIntent(_ intent: Intent?, on r: inout ContextRecord) {
        let previous = r.triage
        r.triage = TriageResult.manual(intent: intent, mentionsDatetime: previous?.mentionsDatetime ?? false)
        // Preserve the prediction being labeled so eval-intent can compare it to the user's truth.
        r.triage?.intentProbabilities = previous?.intentProbabilities
        r.triage?.datetimeProbability = previous?.datetimeProbability
    }

    static func setAnnotation(_ text: String, on r: inout ContextRecord) {
        r.annotation.text = text
        r.annotation.edited = true
    }
}
