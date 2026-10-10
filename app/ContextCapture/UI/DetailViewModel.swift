import AppKit
import CCCore
import CCTriage
import Observation

@Observable
@MainActor
final class DetailViewModel {
    private let store: any RecordStore
    private let guardReview: any GuardReviewing
    private let triage: any TriageQueuing
    private let onChange: @MainActor () -> Void

    private(set) var record: ContextRecord
    /// 注釈の編集中の文字。
    var draftText: String
    /// 表示するスクショ（マスク済みならマスク版）。
    private(set) var image: NSImage?
    private(set) var imageLoaded = false
    private(set) var errorMessage: String?
    private(set) var flash: String?
    private(set) var isWorking = false
    /// 完了・削除したら true（画面を閉じる）。
    private(set) var isClosed = false

    init(record: ContextRecord, store: any RecordStore, guardReview: any GuardReviewing,
         triage: any TriageQueuing = NoopTriageQueue(),
         onChange: @escaping @MainActor () -> Void = {}) {
        self.record = record
        self.draftText = record.annotation.text
        self.store = store
        self.guardReview = guardReview
        self.triage = triage
        self.onChange = onChange
    }

    var isAnnotationChanged: Bool { draftText != record.annotation.text }
    var needsReview: Bool { record.guardInfo.status == .needsReview }
    /// 画像の上に枠を出す検出箇所（要確認のときだけ）。
    var highlightedFindings: [SecretFinding] { needsReview ? record.guardInfo.findings : [] }

    /// 表示する画像の相対パス。マスク済みならマスク版を見せる（外部に渡るのと同じもの）。
    var displayedImagePath: String? {
        if record.guardInfo.status == .masked, let m = record.maskedScreenshotPath { return m }
        return record.screenshotPath
    }

    func load() async {
        defer { imageLoaded = true }
        guard let rel = displayedImagePath, let url = try? await store.attachmentURL(for: rel) else {
            image = nil
            return
        }
        image = NSImage(contentsOf: url)
    }

    func saveAnnotation() async {
        guard isAnnotationChanged else { return }
        let text = draftText
        if await commit(flash: "注釈を保存しました", { RecordEdits.setAnnotation(text, on: &$0) }) {
            // 意図と索引をやり直す（手で変えた意図は上書きされない）。
            let triage = triage, id = record.id
            Task { await triage.annotationEdited(id: id) }
        }
    }

    func revertAnnotation() {
        draftText = record.annotation.text
    }

    /// 意図ラベルを付け替える（nil は未分類）。`TriageResult.manual`（model == "user"）を書くので、自動推定は以後上書きしない。
    func setIntent(_ intent: Intent?) async {
        guard record.triage?.intent != intent || record.triage == nil || record.triage?.isManual == false else { return }
        await commit(flash: nil) { RecordEdits.setManualIntent(intent, on: &$0) }
    }

    func markDone() async {
        if await commit(flash: "完了にしました", { $0.status = .done }) { isClosed = true }
    }

    func delete() async {
        do {
            try await store.delete(id: record.id)
            onChange()
            isClosed = true
        } catch {
            errorMessage = "削除できませんでした。"
        }
    }

    func copyMarkdown() {
        // 編集中の注釈があればそれを含める（見えているものをコピーする）。
        var r = record
        r.annotation.text = draftText
        Clipboard.copyMarkdown(r)
        showFlash("Markdown をコピーしました")
    }

    func markReviewed() async {
        await guardAction { try await self.guardReview.markReviewed(recordID: self.record.id) }
    }

    func useMaskedImage() async {
        await guardAction { try await self.guardReview.useMaskedImage(recordID: self.record.id) }
    }

    private func guardAction(_ op: @escaping () async throws -> ContextRecord) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try await op()
            record = updated
            onChange()
            await load()
        } catch {
            errorMessage = "状態を変えられませんでした。もう一度押してください。"
        }
    }

    /// 最新の記録を読み直して `change` だけを当てて保存する（開いている間にトリアージが書いたガード・意図を巻き戻さない）。
    @discardableResult
    private func commit(flash: String?, _ change: (inout ContextRecord) -> Void) async -> Bool {
        do {
            var r = try await store.get(id: record.id) ?? record
            change(&r)
            try await store.update(r)
            record = r
            draftText = r.annotation.text
            errorMessage = nil
            onChange()
            if let flash { showFlash(flash) }
            return true
        } catch {
            errorMessage = "保存できませんでした。"
            return false
        }
    }

    private func showFlash(_ s: String) {
        flash = s
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if flash == s { flash = nil }
        }
    }
}
