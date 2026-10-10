import CCCore
import Foundation

/// M1 版の検索: 注釈・ウインドウタイトル・URL・アプリ名の部分一致（大文字小文字・全角半角を無視）。
///
/// 埋め込みはまだ無い（Wave 3）。**M2 で `Embedder.embedQuery` → `RecordStore.search(vector:limit:)` の埋め込み検索に替える**
/// （スクショの見た目での検索 F-11 はそこで入る）。クエリは空白で区切り、すべての語を含むものを新しい順に返す。
/// score は語ごとに「注釈で一致 = 1、タイトル等で一致 = 0.5」の平均（並び順の手がかり。同点は新しい順）。
struct SubstringSearchService: SearchServing {
    let store: any RecordStore
    /// 走査する最大件数（M1 の件数なら全件で足りる）。
    var scanLimit = 5_000

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let terms = Self.normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let all = try await store.list(InboxFilter(statuses: [], limit: scanLimit))
        var hits: [SearchHit] = []
        for r in all {
            let annotation = Self.normalize(r.annotation.text)
            let rest = Self.normalize([r.window?.title ?? "", r.url ?? "", r.app.name].joined(separator: "\n"))
            var score: Float = 0
            var all = true
            for t in terms {
                if annotation.contains(t) { score += 1 } else if rest.contains(t) { score += 0.5 } else { all = false; break }
            }
            if all { hits.append(SearchHit(record: r, score: score / Float(terms.count))) }
        }
        // list は新しい順。安定ソートで score の高い順（同点は新しい順のまま）。
        let sorted = hits.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }
        return sorted.prefix(limit).map(\.element)
    }

    static func normalize(_ s: String) -> String {
        (s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s).lowercased()
    }
}
