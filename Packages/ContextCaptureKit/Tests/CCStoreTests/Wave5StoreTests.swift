import CCCore
import Foundation
import XCTest
@testable import CCStore

/// Wave 5 で足した API: `InboxFilter.matches`（SQL と同じ結果）、`idsWithoutEmbedding`、状態で絞る検索。
final class Wave5StoreTests: XCTestCase {
    /// 状態 × triage（無し / 意図あり / 未分類）× ガード × 撮影時刻 の組み合わせを入れる。
    private func seed(_ store: SQLiteRecordStore) async throws -> [ContextRecord] {
        var records: [ContextRecord] = []
        var offset: TimeInterval = 0
        for status in RecordStatus.allCases {
            for triage in 0..<4 {  // 0: 無し, 1: todo, 2: 未分類（intent nil）, 3: note
                for guardStatus in GuardStatus.allCases {
                    offset += 60.5  // 端数を含める
                    let intent: Intent? = triage == 1 ? .todo : (triage == 3 ? .note : nil)
                    let r = makeRecord(at: offset, status: status, intent: intent, triaged: triage == 2,
                                       guardStatus: guardStatus)
                    try await store.insert(r)
                    records.append(r)
                }
            }
        }
        return records
    }

    func testMatchesAgreesWithSQL() async throws {
        let temp = try TempDataRoot()
        let store = try temp.makeStore()
        let all = try await seed(store)
        let mid = all[all.count / 2].capturedAt  // ちょうどその時刻のレコードがある（境界）
        let q1 = all[all.count / 4].capturedAt

        var filters: [InboxFilter] = [
            InboxFilter(),
            InboxFilter(statuses: []),
            InboxFilter(statuses: [.done, .archived]),
            InboxFilter(statuses: [], intent: .todo),
            InboxFilter(statuses: [.inbox], intent: .note),
            InboxFilter(statuses: [], unclassifiedOnly: true),
            InboxFilter(statuses: [], intent: .todo, unclassifiedOnly: true),  // 同時指定は 0 件
            InboxFilter(statuses: [], since: mid),
            InboxFilter(statuses: [], until: mid),
            InboxFilter(statuses: [], since: q1, until: mid),
            InboxFilter(statuses: [], guardStatuses: []),  // 空集合は 0 件
            InboxFilter(statuses: [], guardStatuses: [.needsReview]),
            InboxFilter(statuses: [.inbox, .done], intent: .todo, since: q1, guardStatuses: [.clear, .masked]),
            InboxFilter(statuses: [.archived], unclassifiedOnly: true, until: mid, guardStatuses: [.pending]),
        ]
        for i in filters.indices { filters[i].limit = all.count + 10 }

        for f in filters {
            let sql = Set(try await store.list(f).map(\.id))
            let mem = Set(all.filter(f.matches).map(\.id))
            XCTAssertEqual(sql, mem, "filter \(f)")
            let n = try await store.count(f)
            XCTAssertEqual(n, mem.count, "count \(f)")
        }
        // 0 件になるはずの条件が本当に 0 件か（両方 0 で一致しているだけ、を区別する）
        XCTAssertTrue(all.filter(InboxFilter(statuses: [], intent: .todo, unclassifiedOnly: true).matches).isEmpty)
        XCTAssertTrue(all.filter(InboxFilter(statuses: [], guardStatuses: []).matches).isEmpty)
        XCTAssertFalse(all.filter(InboxFilter(statuses: [], since: mid).matches).isEmpty)
    }

    func testIdsWithAndWithoutEmbedding() async throws {
        let temp = try TempDataRoot()
        let store = try temp.makeStore()
        let a = makeRecord(at: 1), b = makeRecord(at: 2), c = makeRecord(at: 3)
        for r in [a, b, c] { try await store.insert(r) }
        let none = try await store.idsWithEmbedding()
        XCTAssertEqual(none, [])
        let allMissing = try await store.idsWithoutEmbedding()
        XCTAssertEqual(allMissing, [a.id, b.id, c.id])

        try await store.setEmbedding(id: b.id, vector: unitVector([0: 1]))
        let with = try await store.idsWithEmbedding()
        let without = try await store.idsWithoutEmbedding()
        XCTAssertEqual(with, [b.id])
        XCTAssertEqual(without, [a.id, c.id])

        // プロトコル経由（CCTriage が使う形）も同じ。
        let p: any EmbeddingPresenceChecking = store
        let viaProtocol = try await p.idsWithoutEmbedding(dimension: 256)
        XCTAssertEqual(viaProtocol, [a.id, c.id])

        // 次元の違う（古い）埋め込みは「無い」扱い（検索の対象外なので作り直す対象）。
        try await store.pool.write { db in
            try db.execute(sql: "INSERT INTO embeddings (record_id, dim, vector) VALUES (?, 128, ?)",
                           arguments: [c.id, Data(count: 128 * 4)])
        }
        let staleWithout = try await store.idsWithoutEmbedding()
        XCTAssertEqual(staleWithout, [a.id, c.id])
        let staleWith = try await store.idsWithEmbedding()
        XCTAssertEqual(staleWith, [b.id])

        // 削除すると埋め込みも消える。
        try await store.delete(id: b.id)
        let afterDelete = try await store.idsWithEmbedding()
        XCTAssertEqual(afterDelete, [])
    }

    func testSearchFilteredByStatusFillsLimit() async throws {
        let temp = try TempDataRoot()
        let store = try temp.makeStore()
        // archived が上位を占め、inbox は下位にしかない。
        var inboxIDs: [String] = []
        for i in 0..<10 {
            let r = makeRecord(at: TimeInterval(i), status: .archived)
            try await store.insert(r)
            try await store.setEmbedding(id: r.id, vector: unitVector([0: 1, 1: Float(i) * 0.01]))
        }
        for i in 0..<3 {
            let r = makeRecord(at: TimeInterval(100 + i), status: .inbox)
            try await store.insert(r)
            try await store.setEmbedding(id: r.id, vector: unitVector([1: 1, 0: Float(i) * 0.1]))
            inboxIDs.append(r.id)
        }
        let q = unitVector([0: 1])

        let unfiltered = try await store.search(vector: q, limit: 3)
        XCTAssertTrue(unfiltered.allSatisfy { $0.record.status == .archived })

        let inbox = try await store.search(vector: q, limit: 3, statuses: [.inbox])
        XCTAssertEqual(Set(inbox.map(\.record.id)), Set(inboxIDs))
        XCTAssertEqual(inbox.map(\.score), inbox.map(\.score).sorted(by: >))

        // 空集合は全状態（search(vector:limit:) と同じ）。
        let allStatuses = try await store.search(vector: q, limit: 5, statuses: [])
        let plain = try await store.search(vector: q, limit: 5)
        XCTAssertEqual(allStatuses.map(\.record.id), plain.map(\.record.id))

        let done = try await store.search(vector: q, limit: 3, statuses: [.done])
        XCTAssertEqual(done, [])
    }

    func testDateRoundedToMillisecondsSurvivesRoundTrip() async throws {
        let temp = try TempDataRoot()
        let store = try temp.makeStore()
        let raw = Date(timeIntervalSince1970: baseTime + 0.123456789)
        var r = makeRecord()
        r.capturedAt = raw.roundedToMilliseconds
        r.notes = [Note(author: "user", text: "n", at: raw.addingTimeInterval(1).roundedToMilliseconds)]
        try await store.insert(r)
        let back = try await store.get(id: r.id)
        XCTAssertEqual(back, r)
    }
}
