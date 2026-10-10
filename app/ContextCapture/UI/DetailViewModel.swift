import AppKit
import CCCore
import Observation

@Observable
@MainActor
final class DetailViewModel {
    private let store: any RecordStore
    private let guardReview: any GuardReviewing
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
         onChange: @escaping @MainActor () -> Void = {}) {
        self.record = record
        self.draftText = record.annotation.text
        self.store = store
        self.guardReview = guardReview
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
        var r = record
        r.annotation.text = draftText
        r.annotation.edited = true
        await commit(r, flash: "注釈を保存しました")
    }

    func revertAnnotation() {
        draftText = record.annotation.text
    }

    /// 意図ラベルを付け替える（nil は未分類）。
    func setIntent(_ intent: Intent?) async {
        guard record.triage?.intent != intent || record.triage == nil else { return }
        var r = record
        if var t = r.triage {
            t.intent = intent
            r.triage = t
        } else {
            r.triage = TriageResult(intent: intent, intentConfidence: 1, mentionsDatetime: false, model: "user")
        }
        await commit(r, flash: nil)
    }

    func markDone() async {
        var r = record
        r.status = .done
        await commit(r, flash: "完了にしました")
        if errorMessage == nil { isClosed = true }
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

    private func commit(_ r: ContextRecord, flash: String?) async {
        do {
            try await store.update(r)
            record = r
            draftText = r.annotation.text
            errorMessage = nil
            onChange()
            if let flash { showFlash(flash) }
        } catch {
            errorMessage = "保存できませんでした。"
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
