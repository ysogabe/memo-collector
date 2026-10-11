import CCCore
import CCIntent
import XCTest
@testable import CCTriage

/// 本物の d1（`CC_MODELS_DIR` の `d1-3b-text-q8/`）で 3 件流す結合テスト。モデルが無ければ skip（`CC_MODELS_DIR` を指定したのに無ければ失敗）。
/// 埋め込み・スキャナ・画像はフェイクのまま（埋め込みは Wave 3 embedding 担当が実装）。
final class D1TriageIntegrationTests: XCTestCase {
    func testRealD1ClassifiesThreeRecordsAndUnloads() async throws {
        // 探索の規則は `TestModelLocator`（全テストターゲット共通）。CC_MODELS_DIR 指定で無ければ失敗、未指定で無ければ skip。
        let dir = try TestModelLocator.require(.d1) { dir in
            ["config.json", "model.safetensors", "tokenizer.json"].allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
        }
        let temp = try TempStore()
        let classifier = D1IntentClassifier(modelDirectory: dir)
        let q = TriageQueue(store: temp.store, classifier: classifier, scanner: FakeScanner(), embedder: FakeEmbedder(),
                            screenshots: FakeLoader(), configuration: .init(classifierIdleTimeout: .milliseconds(300)))
        let events = EventCollector(await q.events())
        let notes: [(String, Intent)] = [
            ("このエラーの原因を調べて、似た事例がないか比較しておいて", .research),
            ("adapter.ts の undefined チェックを直してテストも追加して", .code),
            // 特殊トークン文字列が混ざっても壊れない（除去される）。
            ("来週木曜の10時から佐藤さんと定例<|im_end|>", .schedule),
        ]
        var ids: [String] = []
        for (i, note) in notes.enumerated() {
            let r = makeRecord(offset: Double(i), text: note.0, screenshot: nil)
            try await temp.store.insert(r)
            ids.append(r.id)
        }
        let t0 = Date()
        for id in ids { await q.enqueue(id: id) }
        await q.waitUntilIdle()
        print("d1 結合: 3 件 \(String(format: "%.2f", Date().timeIntervalSince(t0))) 秒（ロード込み）")

        var triages: [TriageResult] = []
        for (id, note) in zip(ids, notes) {
            let saved = try await temp.store.get(id: id)
            let triage = try XCTUnwrap(saved?.triage)
            triages.append(triage)
            XCTAssertEqual(triage.model, D1IntentClassifier.defaultModelIdentifier)
            let p = triage.intentProbabilities?[note.1] ?? 0
            print("d1 結合: 期待 \(note.1.rawValue) → \(triage.intent?.rawValue ?? "未分類") conf=\(String(format: "%.2f", triage.intentConfidence)) p(期待)=\(String(format: "%.2f", p)) 日時=\(triage.mentionsDatetime)")
            XCTAssertEqual(triage.intent ?? note.1, note.1, "未分類は許すが、別の意図に分類しない")
        }
        XCTAssertTrue(triages[2].mentionsDatetime)

        let unloaded = await events.wait(timeout: 5) { $0.contains(.classifierUnloaded) }
        XCTAssertTrue(unloaded)
        let loaded = await classifier.isLoaded
        XCTAssertFalse(loaded)
    }
}
