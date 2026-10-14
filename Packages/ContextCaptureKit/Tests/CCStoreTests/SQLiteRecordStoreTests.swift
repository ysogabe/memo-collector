import CCCore
import Foundation
import GRDB
import XCTest
@testable import CCStore

final class SQLiteRecordStoreTests: XCTestCase {
    var root: TempDataRoot!
    var store: SQLiteRecordStore!

    override func setUpWithError() throws {
        root = try TempDataRoot()
        store = try root.makeStore()
    }

    override func tearDown() {
        store = nil
        root = nil
    }

    // MARK: - CRUD

    func testInsertGetUpdate() async throws {
        var r = makeRecord(text: "最初")
        try await store.insert(r)
        let fetched = try await store.get(id: r.id)
        XCTAssertEqual(fetched, r)

        r.annotation.text = "直した"
        r.annotation.edited = true
        r.status = .done
        r.triage = TriageResult(intent: .todo, intentConfidence: 0.9, mentionsDatetime: true, model: "m")
        try await store.update(r)
        let updated = try await store.get(id: r.id)
        XCTAssertEqual(updated, r)
        // 列も追従している（status / intent で引ける）
        let done = try await store.list(InboxFilter(statuses: [.done], intent: .todo))
        XCTAssertEqual(done.map(\.id), [r.id])
    }

    func testGetMissingReturnsNil() async throws {
        let missing = try await store.get(id: "01JA9Z3K8Q4V7X2M5N6P8R0T1W")
        XCTAssertNil(missing)
    }

    func testDuplicateInsertThrows() async throws {
        let r = makeRecord()
        try await store.insert(r)
        do {
            try await store.insert(r)
            XCTFail("throw されるべき")
        } catch let e as CCStoreError {
            XCTAssertEqual(e, .duplicateID(r.id))
        }
    }

    func testUpdateMissingThrows() async throws {
        let r = makeRecord()
        do {
            try await store.update(r)
            XCTFail("throw されるべき")
        } catch let e as CCStoreError {
            XCTAssertEqual(e, .notFound(r.id))
        }
    }

    func testPRDExampleRoundTrip() async throws {
        let record = try CCJSON.decoder().decode(ContextRecord.self, from: Data(prdRecordJSON.utf8))
        try await store.insert(record)
        let fetched = try await store.get(id: record.id)
        XCTAssertEqual(fetched, record)
        XCTAssertEqual(fetched?.guardInfo.status, .needsReview)
        XCTAssertEqual(fetched?.triage?.intent, .code)
        XCTAssertEqual(fetched?.handoffs.first?.to, "claude-code")
        XCTAssertEqual(fetched?.window?.frame, CGRect(x: 0, y: 38, width: 1440, height: 862))

        // 列にも PRD の値が出ている
        let cols = try await store.pool.read { db -> [String: String] in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM records WHERE id = ?", arguments: [record.id])!
            return [
                "status": row["status"], "intent": row["intent"], "guard_status": row["guard_status"],
                "app_bundle_id": row["app_bundle_id"], "has_triage": String(row["has_triage"] as Bool),
                "captured_at": String(row["captured_at"] as Double),
            ]
        }
        XCTAssertEqual(cols["status"], "inbox")
        XCTAssertEqual(cols["intent"], "code")
        XCTAssertEqual(cols["guard_status"], "needs_review")
        XCTAssertEqual(cols["app_bundle_id"], "com.google.Chrome")
        XCTAssertEqual(cols["has_triage"], "true")
        XCTAssertEqual(cols["captured_at"], String(record.capturedAt.timeIntervalSince1970))
    }

    // MARK: - list / count

    func testListOrderAndPaging() async throws {
        let rs = (0..<5).map { makeRecord(at: TimeInterval($0) * 60) }
        for r in rs.shuffled() { try await store.insert(r) }
        let all = try await store.list(InboxFilter(limit: 10))
        XCTAssertEqual(all.map(\.id), rs.reversed().map(\.id))
        let page = try await store.list(InboxFilter(limit: 2, offset: 1))
        XCTAssertEqual(page.map(\.id), [rs[3].id, rs[2].id])
        let none = try await store.list(InboxFilter(limit: 0))
        XCTAssertEqual(none, [])
        let total = try await store.count(InboxFilter(limit: 1, offset: 3))
        XCTAssertEqual(total, 5, "count は limit / offset を無視する")
    }

    func testFilters() async throws {
        let a = makeRecord(at: 0, status: .inbox, intent: .code, guardStatus: .clear)
        let b = makeRecord(at: 100, status: .inbox, triaged: true, guardStatus: .needsReview)  // 未分類
        let c = makeRecord(at: 200, status: .done, intent: .todo, guardStatus: .masked)
        let d = makeRecord(at: 300, status: .archived, guardStatus: .pending)  // 未トリアージ
        let e = makeRecord(at: 400, status: .inbox, intent: .code, guardStatus: .clear)
        for r in [a, b, c, d, e] { try await store.insert(r) }

        func ids(_ f: InboxFilter) async throws -> [String] {
            let listed = try await store.list(f).map(\.id)
            let n = try await store.count(f)
            XCTAssertEqual(n, listed.count, "count と list の件数が合わない: \(f)")
            return listed
        }

        // 既定は inbox のみ
        let inbox = try await ids(.inbox)
        XCTAssertEqual(inbox, [e.id, b.id, a.id])
        // statuses 空 = 全状態
        let allStatus = try await ids(InboxFilter(statuses: []))
        XCTAssertEqual(allStatus, [e.id, d.id, c.id, b.id, a.id])
        let doneArchived = try await ids(InboxFilter(statuses: [.done, .archived]))
        XCTAssertEqual(doneArchived, [d.id, c.id])
        // intent
        let code = try await ids(InboxFilter(statuses: [], intent: .code))
        XCTAssertEqual(code, [e.id, a.id])
        // 未分類 = triage あり & intent nil（未トリアージの d は含まない）
        let unclassified = try await ids(InboxFilter(statuses: [], unclassifiedOnly: true))
        XCTAssertEqual(unclassified, [b.id])
        // intent と unclassifiedOnly の同時指定は空
        let conflicting = try await ids(InboxFilter(statuses: [], intent: .code, unclassifiedOnly: true))
        XCTAssertEqual(conflicting, [])
        // since は含む、until は含まない
        let range = try await ids(InboxFilter(statuses: [], since: ms(baseTime + 100), until: ms(baseTime + 300)))
        XCTAssertEqual(range, [c.id, b.id])
        // guardStatuses
        let guards = try await ids(InboxFilter(statuses: [], guardStatuses: [.clear, .masked]))
        XCTAssertEqual(guards, [e.id, c.id, a.id])
        let emptyGuards = try await ids(InboxFilter(statuses: [], guardStatuses: []))
        XCTAssertEqual(emptyGuards, [], "guardStatuses の空集合は 0 件")
        // 組み合わせ
        let combo = try await ids(InboxFilter(statuses: [.inbox], intent: .code, since: ms(baseTime + 1), guardStatuses: [.clear]))
        XCTAssertEqual(combo, [e.id])
    }

    // MARK: - 検索

    func testSearchRanking() async throws {
        let r1 = makeRecord(at: 0), r2 = makeRecord(at: 1), r3 = makeRecord(at: 2), r4 = makeRecord(at: 3)
        let noEmbedding = makeRecord(at: 4)
        for r in [r1, r2, r3, r4, noEmbedding] { try await store.insert(r) }
        try await store.setEmbedding(id: r1.id, vector: unitVector([0: 1]))
        try await store.setEmbedding(id: r2.id, vector: unitVector([0: 1, 1: 1]))
        try await store.setEmbedding(id: r3.id, vector: unitVector([1: 1]))
        try await store.setEmbedding(id: r4.id, vector: unitVector([0: -1]))
        // archived も検索対象
        try await store.setStatus(id: r3.id, .archived)

        let query = unitVector([0: 1, 1: 0.2])
        let hits = try await store.search(vector: query, limit: 10)
        XCTAssertEqual(hits.map(\.record.id), [r1.id, r2.id, r3.id, r4.id])
        XCTAssertEqual(hits[0].score, unitVector([0: 1, 1: 0.2])[0], accuracy: 1e-5)
        XCTAssertEqual(hits[3].score, -hits[0].score, accuracy: 1e-5)
        XCTAssertEqual(hits[2].record.status, .archived)

        let top2 = try await store.search(vector: query, limit: 2)
        XCTAssertEqual(top2.map(\.record.id), [r1.id, r2.id])

        // 置換
        try await store.setEmbedding(id: r4.id, vector: unitVector([0: 1, 1: 0.2]))
        let replaced = try await store.search(vector: query, limit: 1)
        XCTAssertEqual(replaced.first?.record.id, r4.id)
        XCTAssertEqual(replaced.first?.score ?? 0, 1, accuracy: 1e-5)
    }

    func testSearchEmptyAndValidation() async throws {
        let empty = try await store.search(vector: unitVector([0: 1]), limit: 5)
        XCTAssertEqual(empty, [])
        let r = makeRecord()
        try await store.insert(r)
        do {
            try await store.setEmbedding(id: r.id, vector: [1, 0, 0])
            XCTFail("throw されるべき")
        } catch let e as CCStoreError {
            XCTAssertEqual(e, .dimensionMismatch(expected: 256, actual: 3))
        }
        do {
            _ = try await store.search(vector: [1], limit: 5)
            XCTFail("throw されるべき")
        } catch let e as CCStoreError {
            XCTAssertEqual(e, .dimensionMismatch(expected: 256, actual: 1))
        }
        do {
            try await store.setEmbedding(id: "missing", vector: unitVector([0: 1]))
            XCTFail("throw されるべき")
        } catch let e as CCStoreError {
            XCTAssertEqual(e, .notFound("missing"))
        }
    }

    func testSearchSeesEmbeddingChangesFromOtherConnection() async throws {
        let other = try root.makeStore()
        let a = makeRecord(at: 0), b = makeRecord(at: 1)
        try await store.insert(a)
        try await store.insert(b)
        try await store.setEmbedding(id: a.id, vector: unitVector([0: 1]))
        let q = unitVector([1: 1])
        let first = try await store.search(vector: q, limit: 5)  // キャッシュが埋まる
        XCTAssertEqual(first.map(\.record.id), [a.id])

        // 別接続（別プロセス相当）で追加・置換・削除 → 同じ store の検索に反映される
        try await other.setEmbedding(id: b.id, vector: unitVector([1: 1]))
        let added = try await store.search(vector: q, limit: 5)
        XCTAssertEqual(added.map(\.record.id), [b.id, a.id])
        try await other.setEmbedding(id: a.id, vector: unitVector([1: 1, 2: 0.01]))
        let replaced = try await store.search(vector: q, limit: 1)
        XCTAssertEqual(replaced.first?.record.id, b.id)
        let both = try await store.search(vector: q, limit: 2)
        XCTAssertGreaterThan(both.last?.score ?? 0, 0.99)
        try await other.delete(id: b.id)
        let afterDelete = try await store.search(vector: q, limit: 5)
        XCTAssertEqual(afterDelete.map(\.record.id), [a.id])
    }

    func testTopKTieBreak() {
        let idx = SQLiteRecordStore.topK(scores: [0.5, 0.9, 0.5, 0.1, 0.9], ids: ["a", "b", "c", "d", "e"], k: 3)
        XCTAssertEqual(idx, [4, 1, 2])
    }

    // MARK: - 添付と削除

    func testWriteAttachmentAndDelete() async throws {
        var r = makeRecord(at: 0)
        let shot = try await store.writeAttachment(Data([1, 2, 3]), id: r.id, kind: .screenshot, ext: "webp", capturedAt: r.capturedAt)
        let masked = try await store.writeAttachment(Data([4]), id: r.id, kind: .maskedScreenshot, ext: ".webp", capturedAt: r.capturedAt)
        let audio = try await store.writeAttachment(Data([5]), id: r.id, kind: .audio, ext: "m4a", capturedAt: r.capturedAt)
        XCTAssertEqual(shot, "captures/2026/10/08/\(r.id).webp")
        XCTAssertEqual(masked, "captures/2026/10/08/\(r.id)-masked.webp")
        XCTAssertEqual(audio, "captures/2026/10/08/\(r.id).m4a")
        let shotURL = try await store.attachmentURL(for: shot)
        XCTAssertEqual(try Data(contentsOf: shotURL), Data([1, 2, 3]))

        // 上書きも原子的に置き換わる
        _ = try await store.writeAttachment(Data([9, 9]), id: r.id, kind: .screenshot, ext: "webp", capturedAt: r.capturedAt)
        XCTAssertEqual(try Data(contentsOf: shotURL), Data([9, 9]))

        // マスク版はレコードに書かないまま（書き込み後に落ちた想定）でも delete で消える
        r.screenshotPath = shot
        r.audioPath = audio
        try await store.insert(r)
        try await store.setEmbedding(id: r.id, vector: unitVector([0: 1]))
        let other = makeRecord(at: 10)
        try await store.insert(other)
        let otherShot = try await store.writeAttachment(Data([7]), id: other.id, kind: .screenshot, ext: "webp", capturedAt: other.capturedAt)

        try await store.delete(id: r.id)
        let gone = try await store.get(id: r.id)
        XCTAssertNil(gone)
        for rel in [shot, masked, audio] {
            let url = try await store.attachmentURL(for: rel)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), rel)
        }
        let embeddings = try await store.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings")! }
        XCTAssertEqual(embeddings, 0)
        // 他レコードの添付は残る
        let otherURL = try await store.attachmentURL(for: otherShot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherURL.path))

        // 無い id の削除は何もしない
        try await store.delete(id: r.id)
    }

    func testAttachmentURLRejectsEscapes() async throws {
        do {
            _ = try await store.attachmentURL(for: "../etc/passwd")
            XCTFail("throw されるべき")
        } catch {}
    }

    // MARK: - 保持期間

    func testPurgeExpiredAudio() async throws {
        let now = ms(baseTime + 10 * 86400)
        var old = makeRecord(at: 0, text: "古い注釈")  // 10 日前
        var fresh = makeRecord(at: 5 * 86400)  // 5 日前
        old.audioPath = try await store.writeAttachment(Data([1]), id: old.id, kind: .audio, ext: "m4a", capturedAt: old.capturedAt)
        old.screenshotPath = try await store.writeAttachment(Data([2]), id: old.id, kind: .screenshot, ext: "webp", capturedAt: old.capturedAt)
        fresh.audioPath = try await store.writeAttachment(Data([3]), id: fresh.id, kind: .audio, ext: "m4a", capturedAt: fresh.capturedAt)
        try await store.insert(old)
        try await store.insert(fresh)

        let purged = try await store.purgeExpiredAudio(now: now)
        XCTAssertEqual(purged, 1)
        let o = try await store.get(id: old.id)
        XCTAssertNil(o?.audioPath)
        XCTAssertEqual(o?.annotation.text, "古い注釈")
        XCTAssertEqual(o?.screenshotPath, old.screenshotPath, "スクショは残る")
        let oldAudioURL = try await store.attachmentURL(for: old.audioPath!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudioURL.path))
        let f = try await store.get(id: fresh.id)
        XCTAssertEqual(f?.audioPath, fresh.audioPath)
        let freshAudioURL = try await store.attachmentURL(for: fresh.audioPath!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshAudioURL.path))
        // 列も nil に追従している
        let audioRows = try await store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records WHERE audio_path IS NOT NULL")!
        }
        XCTAssertEqual(audioRows, 1)
        // 2 回目は何もしない
        let again = try await store.purgeExpiredAudio(now: now)
        XCTAssertEqual(again, 0)
    }

    func testPurgeExpiredScreenshots() async throws {
        let now = ms(baseTime + 40 * 86400)
        var old = makeRecord(at: 0)
        old.screenshotPath = try await store.writeAttachment(Data([1]), id: old.id, kind: .screenshot, ext: "webp", capturedAt: old.capturedAt)
        old.maskedScreenshotPath = try await store.writeAttachment(Data([2]), id: old.id, kind: .maskedScreenshot, ext: "webp", capturedAt: old.capturedAt)
        old.audioPath = "captures/2026/10/08/\(old.id).m4a"
        let fresh = makeRecord(at: 39 * 86400)
        try await store.insert(old)
        try await store.insert(fresh)

        let unlimited = try await store.purgeExpiredScreenshots(retentionDays: nil, now: now)
        XCTAssertEqual(unlimited, 0)
        let kept = try await store.get(id: old.id)
        XCTAssertEqual(kept?.screenshotPath, old.screenshotPath)

        let purged = try await store.purgeExpiredScreenshots(retentionDays: 30, now: now)
        XCTAssertEqual(purged, 1)
        let o = try await store.get(id: old.id)
        XCTAssertNil(o?.screenshotPath)
        XCTAssertNil(o?.maskedScreenshotPath)
        XCTAssertEqual(o?.audioPath, old.audioPath, "音声はスクショの保持期間では消さない")
        for rel in [old.screenshotPath!, old.maskedScreenshotPath!] {
            let url = try await store.attachmentURL(for: rel)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// 保持期間でスクショを消したら、ガードの判定も「画像なし」（clear・検出なし）にする。Inbox の要確認から外れる。
    /// 受け渡しの履歴は残す。
    func testPurgeExpiredScreenshotsClearsGuardInfo() async throws {
        let now = ms(baseTime + 40 * 86400)
        var review = makeRecord(at: 0, guardStatus: .needsReview)
        review.guardInfo.findings = [SecretFinding(kind: "api_key", bbox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05))]
        review.screenshotPath = try await store.writeAttachment(Data([1]), id: review.id, kind: .screenshot, ext: "heic", capturedAt: review.capturedAt)
        review.handoffs = [Handoff(to: "claude-code", at: ms(baseTime + 10), via: "mcp")]
        var masked = makeRecord(at: 1, guardStatus: .masked)
        masked.screenshotPath = try await store.writeAttachment(Data([1]), id: masked.id, kind: .screenshot, ext: "heic", capturedAt: masked.capturedAt)
        masked.maskedScreenshotPath = try await store.writeAttachment(Data([2]), id: masked.id, kind: .maskedScreenshot, ext: "heic", capturedAt: masked.capturedAt)
        let freshReview = makeRecord(at: 39 * 86400, guardStatus: .needsReview)
        for r in [review, masked, freshReview] { try await store.insert(r) }

        let reviewFilter = InboxFilter(statuses: [], guardStatuses: [.needsReview])
        let before = try await store.count(reviewFilter)
        XCTAssertEqual(before, 2)

        let purged = try await store.purgeExpiredScreenshots(retentionDays: 30, now: now)
        XCTAssertEqual(purged, 2)
        let r = try await store.get(id: review.id)
        XCTAssertEqual(r?.guardInfo, GuardInfo(status: .clear, findings: []))
        XCTAssertEqual(r?.handoffs, review.handoffs, "受け渡しの履歴は残す")
        let m = try await store.get(id: masked.id)
        XCTAssertEqual(m?.guardInfo, GuardInfo(status: .clear, findings: []))
        XCTAssertNil(m?.maskedScreenshotPath)
        let f = try await store.get(id: freshReview.id)
        XCTAssertEqual(f?.guardInfo.status, .needsReview, "期限内の記録はそのまま")

        let after = try await store.count(reviewFilter)
        XCTAssertEqual(after, 1, "消した記録は要確認の件数から外れる")
        let rows = try await store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records WHERE guard_status = 'needs_review'")!
        }
        XCTAssertEqual(rows, 1, "列も追従している")
    }

    // MARK: - 追記・状態更新

    func testMutations() async throws {
        let r = makeRecord()
        try await store.insert(r)
        let note = Note(author: "claude-code", text: "PR を作った", at: ms(baseTime + 60))
        let afterNote = try await store.appendNote(id: r.id, note: note)
        XCTAssertEqual(afterNote.notes, [note])
        let handoff = Handoff(to: "claude-code", at: ms(baseTime + 30), via: "mcp")
        try await store.appendHandoff(id: r.id, handoff)
        try await store.setStatus(id: r.id, .done)
        let fetched = try await store.get(id: r.id)
        XCTAssertEqual(fetched?.notes, [note])
        XCTAssertEqual(fetched?.handoffs, [handoff])
        XCTAssertEqual(fetched?.status, .done)
        let inboxCount = try await store.count(.inbox)
        XCTAssertEqual(inboxCount, 0)

        do {
            try await store.setStatus(id: "missing", .done)
            XCTFail("throw されるべき")
        } catch let e as CCStoreError {
            XCTAssertEqual(e, .notFound("missing"))
        }
    }

    // MARK: - 並行・マイグレーション

    func testConcurrentWritersFromTwoConnections() async throws {
        let other = try root.makeStore()
        let target = makeRecord()
        try await store.insert(target)
        let stores: [SQLiteRecordStore] = [store, other]
        let perStore = 20  // 多すぎると SQLite のビジー待ち（バックオフ）で片側が飢えて busyTimeout を超える

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (s, st) in stores.enumerated() {
                for i in 0..<perStore {
                    group.addTask {
                        try await st.insert(makeRecord(at: TimeInterval(s * 1000 + i + 1)))
                        try await st.appendNote(
                            id: target.id,
                            note: Note(author: "s\(s)", text: "n\(i)", at: ms(baseTime + Double(i)))
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        let n = try await other.count(InboxFilter(statuses: []))
        XCTAssertEqual(n, 2 * perStore + 1)
        let notes = try await store.get(id: target.id)?.notes ?? []
        XCTAssertEqual(notes.count, 2 * perStore, "同時追記で上書き事故が起きていない")
        XCTAssertEqual(Set(notes.map { "\($0.author)-\($0.text)" }).count, 2 * perStore)
    }

    func testWALMode() async throws {
        let mode = try await store.pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode")! }
        XCTAssertEqual(mode.lowercased(), "wal")
    }

    func testMigrationIsIdempotent() async throws {
        let r = makeRecord()
        try await store.insert(r)
        store = nil
        // 開き直し（マイグレーション再実行）でデータが残り、エラーにならない
        let reopened = try root.makeStore()
        try StoreSchema.migrator.migrate(reopened.pool)
        let applied = try await reopened.pool.read { db in try StoreSchema.migrator.appliedMigrations(db) }
        XCTAssertEqual(applied, ["v1", "v2_index_generations"])
        let fetched = try await reopened.get(id: r.id)
        XCTAssertEqual(fetched, r)
        let hasNew = try await reopened.pool.read { db in try StoreSchema.migrator.hasCompletedMigrations(db) }
        XCTAssertTrue(hasNew)
    }
}

/// CCCoreTests/Fixtures/prd_record.json と同じ内容（Package.swift を触らずに共有できないため複製）。
let prdRecordJSON = """
{
  "id": "01JA9Z3K8Q4V7X2M5N6P8R0T1W",
  "captured_at": "2026-10-08T23:15:32+09:00",
  "app": { "name": "Google Chrome", "bundle_id": "com.google.Chrome" },
  "window": { "title": "Support streaming events · Issue #128", "frame": [0, 38, 1440, 862] },
  "url": "https://github.com/opendots/opendots/issues/128",
  "extra": {},
  "screenshot": "captures/2026/10/08/231532.webp",
  "audio": "captures/2026/10/08/231532.m4a",
  "annotation": { "text": "このissueの修正、Claude Codeにやらせて", "stt_engine": "whisper-large-v3-turbo", "edited": false },
  "triage": {
    "intent": "code", "intent_confidence": 0.84, "mentions_datetime": false,
    "model": "LiquidAI/d1-3B@051bcc4"
  },
  "guard": { "status": "needs_review", "findings": [ { "kind": "github_token", "bbox": [0.1, 0.25, 0.3, 0.05] } ] },
  "handoff": [ { "to": "claude-code", "at": "2026-10-09T09:00:00+09:00", "via": "mcp" } ],
  "status": "inbox"
}
"""
