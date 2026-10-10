import AppKit
import CCCore
import Observation

/// Inbox の絞り込み（意図フィルタ）。
enum InboxScope: Hashable, CaseIterable, Identifiable {
    case all
    case intent(Intent)
    case unclassified
    case needsReview

    static var allCases: [InboxScope] { [.all] + Intent.allCases.map { .intent($0) } + [.unclassified, .needsReview] }

    var id: String { title }

    var title: String {
        switch self {
        case .all: return "すべて"
        case let .intent(i): return i.rawValue
        case .unclassified: return "未分類"
        case .needsReview: return "要確認"
        }
    }

    var filter: InboxFilter {
        switch self {
        case .all: return InboxFilter(limit: 500)
        case let .intent(i): return InboxFilter(intent: i, limit: 500)
        case .unclassified: return InboxFilter(unclassifiedOnly: true, limit: 500)
        case .needsReview: return InboxFilter(guardStatuses: [.needsReview], limit: 500)
        }
    }
}

struct InboxDaySection: Identifiable, Equatable {
    var id: Date { day }
    var day: Date
    var title: String
    var records: [ContextRecord]
}

@Observable
@MainActor
final class InboxViewModel {
    private let store: any RecordStore
    private let search: any SearchServing
    private let now: @Sendable () -> Date
    private let onChange: @MainActor () -> Void

    var scope: InboxScope = .all
    /// 検索欄の文字。確定（Enter）で検索する。
    var query = ""
    private(set) var sections: [InboxDaySection] = []
    /// 検索結果を出しているときだけ非 nil。
    private(set) var searchResults: [SearchHit]?
    /// 結果を出している検索語。
    private(set) var searchedQuery: String?
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    var selection: String?
    /// 削除の確認を出している記録。
    var pendingDelete: ContextRecord?
    /// 「コピーしました」などの一時表示。
    private(set) var flash: String?

    init(store: any RecordStore, search: any SearchServing, now: @escaping @Sendable () -> Date,
         onChange: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.search = search
        self.now = now
        self.onChange = onChange
    }

    /// 表示中の行（検索中は検索結果）。キーボード操作で使う。
    var visibleRecords: [ContextRecord] {
        if let hits = searchResults { return hits.map(\.record) }
        return sections.flatMap(\.records)
    }

    var isEmpty: Bool { hasLoaded && visibleRecords.isEmpty }

    func load() async {
        do {
            let records = try await store.list(scope.filter)
            sections = Self.group(records, now: now())
            errorMessage = nil
        } catch {
            errorMessage = "記録を読み込めませんでした。"
        }
        hasLoaded = true
        if let s = selection, !visibleRecords.contains(where: { $0.id == s }) { selection = nil }
    }

    func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clearSearch(); return }
        isSearching = true
        defer { isSearching = false }
        do {
            // 検索は状態を問わず探す（完了にしたものも見つけられる）。意図フィルタは結果にも掛ける。
            let hits = try await search.search(q, limit: 30)
            searchResults = hits.filter { InboxViewModel.matchesScope($0.record, scope) }
            searchedQuery = q
            selection = searchResults?.first?.record.id
            errorMessage = nil
        } catch {
            errorMessage = "検索できませんでした。もう一度 Enter を押してください。"
        }
    }

    func clearSearch() {
        query = ""
        searchResults = nil
        searchedQuery = nil
    }

    func record(id: String) -> ContextRecord? {
        visibleRecords.first { $0.id == id }
    }

    func copyMarkdown(id: String) {
        guard let r = record(id: id) else { return }
        Clipboard.copyMarkdown(r)
        showFlash("Markdown をコピーしました")
    }

    func requestDelete(id: String?) {
        guard let id, let r = record(id: id) else { return }
        pendingDelete = r
    }

    func confirmDelete() async {
        guard let r = pendingDelete else { return }
        pendingDelete = nil
        do {
            try await store.delete(id: r.id)
            searchResults?.removeAll { $0.record.id == r.id }
            showFlash("削除しました")
            onChange()
            await load()
        } catch {
            errorMessage = "削除できませんでした。"
        }
    }

    private func showFlash(_ s: String) {
        flash = s
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if flash == s { flash = nil }
        }
    }

    static func matchesScope(_ r: ContextRecord, _ scope: InboxScope) -> Bool {
        var f = scope.filter
        f.statuses = []
        return f.matches(r)
    }

    static func group(_ records: [ContextRecord], now: Date, calendar: Calendar = .current) -> [InboxDaySection] {
        var out: [InboxDaySection] = []
        for r in records.sorted(by: { $0.capturedAt > $1.capturedAt }) {
            let day = calendar.startOfDay(for: r.capturedAt)
            if out.last?.day == day {
                out[out.count - 1].records.append(r)
            } else {
                out.append(InboxDaySection(day: day, title: DateText.dayHeading(day, now: now, calendar: calendar), records: [r]))
            }
        }
        return out
    }
}

@MainActor
enum Clipboard {
    static func copyMarkdown(_ record: ContextRecord) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(RecordMarkdown.render(record, includeScreenshotLink: true), forType: .string)
    }
}

extension InboxFilter {
    /// `InboxFilter` の意味（CCCore のドキュメント）どおりに 1 件を判定する。limit / offset は見ない。
    func matches(_ r: ContextRecord) -> Bool {
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
