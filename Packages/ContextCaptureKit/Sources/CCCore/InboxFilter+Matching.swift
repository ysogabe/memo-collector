import Foundation

extension InboxFilter {
    /// 記録 1 件がこの絞り込み条件に合うか（純粋関数。`limit` / `offset` は見ない）。
    ///
    /// CCStore の SQL（`SQLiteRecordStore.list` / `count` の WHERE 句）と同じ意味:
    /// - `statuses` が空集合なら状態の条件なし
    /// - `intent` があれば `triage?.intent == intent`
    /// - `unclassifiedOnly` は「triage はあるが intent が nil」。`intent` と同時指定すると常に false
    /// - `since` は含む（`>=`）、`until` は含まない（`<`）
    /// - `guardStatuses` が nil なら条件なし、空集合なら常に false
    ///
    /// メモリ上の一覧（フェイクのストア、UI の楽観的更新）を SQL と同じ規則で絞るために使う。
    public func matches(_ r: ContextRecord) -> Bool {
        if !statuses.isEmpty && !statuses.contains(r.status) { return false }
        if let intent, r.triage?.intent != intent { return false }
        if unclassifiedOnly {
            guard let t = r.triage, t.intent == nil, intent == nil else { return false }
        }
        if let since, r.capturedAt < since { return false }
        if let until, r.capturedAt >= until { return false }
        if let g = guardStatuses, !g.contains(r.guardInfo.status) { return false }
        return true
    }
}
