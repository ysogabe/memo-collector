import CCCore
import CCTriage
import Foundation

/// 保存〜トリアージ〜画面更新の配線（F-09 / F-10 / F-11）。`LiveServices` が 1 つ持つ。
///
/// - 保存直後（`AppCoordinator.onRecordSaved`）→ `enqueue(id:)`
/// - 注釈の編集（詳細ビュー）→ `annotationEdited(id:)`（= `reprocess(id:)`。手で変えた意図は上書きされない）
/// - `TriageQueue.events()` を購読し、ガードか意図を書いた記録が終わったら `onRecordsChanged`（= `AppModel.recordsDidChange()`）。
///   索引だけの更新は画面に出ないので知らせない（索引の作り直しで Inbox を何百回も読み直さないため）
/// - 取り消し（`onRecordRemoved`）はキューから外す API が無いが、キューは処理時に `store.get` で消えた記録を
///   `.recordMissing` で飛ばすので何もしなくてよい
@MainActor
final class TriageWiring {
    let queue: any TriageQueuing
    var onRecordsChanged: @MainActor () -> Void = {}
    /// d1 を解放したとき（デバッグ表示の更新用）。
    var onClassifierUnloaded: @MainActor () -> Void = {}

    /// 処理中の記録のうち、画面に出るもの（ガード・意図）を書いたもの。
    private var visiblyChanged: Set<String> = []
    private var observer: Task<Void, Never>?

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
                CCLog.triage.info("\(id, privacy: .public) \(step.rawValue, privacy: .public): ok")
            case let .skipped(reason):
                CCLog.triage.info("\(id, privacy: .public) \(step.rawValue, privacy: .public): skipped \(reason.rawValue, privacy: .public)")
            case let .failed(detail):
                // detail は型名とエラーコードだけ（本文・秘密を含まない。TriageQueue.describe）。
                CCLog.triage.notice("\(id, privacy: .public) \(step.rawValue, privacy: .public): failed \(detail, privacy: .public)")
            }
        case let .recordFinished(id):
            if visiblyChanged.remove(id) != nil { onRecordsChanged() }
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
        r.triage = TriageResult.manual(intent: intent, mentionsDatetime: r.triage?.mentionsDatetime ?? false)
    }

    static func setAnnotation(_ text: String, on r: inout ContextRecord) {
        r.annotation.text = text
        r.annotation.edited = true
    }
}
