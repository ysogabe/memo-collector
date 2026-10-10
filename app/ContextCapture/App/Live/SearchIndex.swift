import CCCore
import Foundation

// 状態ファイル `search-index.json` の型 `SearchIndexState` は CCCore（cc-mcp と共有）。

/// 埋め込みの準備と索引の整合を保つ（F-11）。
///
/// `activate(imageTokens:)`（起動時・モデル準備の後・画像トークン数の変更時）:
/// 1. 埋め込みを作れなければ（モデルが無い）`.unavailable`。ガードと意図のために `resumePending()` だけ呼ぶ
/// 2. `SwitchableEmbedder.install`（バックグラウンドで ANE の初回特殊化。UI は固めない）→ `.preparing`
/// 3. 保存済みのシグネチャ（`search-index.json`）と比べ、同じで `ready` なら `.ready` で `resumePending()`（埋め込みの無い記録を拾う）
/// 4. 同じで `degraded`（前回の作り直しで一部が失敗）なら、**失敗した記録（`failed_ids`）だけ**やり直す
/// 5. 違う・無い・`rebuilding` なら `.rebuilding`: 状態ファイルを `rebuilding` にしてから全件に索引を積み、終わるまで待つ
///    （作り直しの途中で落ちても、次の起動で `rebuilding` のまま → もう一度作り直す。混ざった索引を残さない）
/// 6. 索引できなかった記録が残れば 1 回だけやり直し、それでも残れば **`ready` にしない**: 状態ファイルは
///    `degraded`（`failed_ids` つき。cc-mcp はベクトル検索を使わない）、表示は `.degraded(failed:)`。全部できたら `ready`
@MainActor
final class SearchIndexMaintainer {
    typealias EmbedderFactory = @MainActor (_ imageTokens: Int) -> (any PreparableEmbedder)?

    let embedder: SwitchableEmbedder
    private let queue: any TriageQueuing
    private let store: any RecordStore
    private let stateURL: URL
    private let makeEmbedder: EmbedderFactory
    /// 状態が変わるたびに呼ぶ（メニューバーの表示）。
    var onReadinessChange: @MainActor (SearchReadiness) -> Void = { _ in }

    private(set) var readiness: SearchReadiness = .unavailable {
        didSet { if readiness != oldValue { onReadinessChange(readiness) } }
    }
    /// 今の埋め込みの画像トークン数（未作成なら nil）。
    private(set) var activeImageTokens: Int?
    private var generation = 0
    private var task: Task<Void, Never>?

    init(embedder: SwitchableEmbedder, queue: any TriageQueuing, store: any RecordStore, stateURL: URL,
         makeEmbedder: @escaping EmbedderFactory) {
        self.embedder = embedder
        self.queue = queue
        self.store = store
        self.stateURL = stateURL
        self.makeEmbedder = makeEmbedder
    }

    /// 埋め込みを（作り直して）準備し、索引を合わせる。前の `activate` の途中なら、その続きは捨てる。
    @discardableResult
    func activate(imageTokens: Int) -> Task<Void, Never> {
        generation += 1
        let gen = generation
        task?.cancel()
        let t = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.run(imageTokens: imageTokens, generation: gen)
        }
        task = t
        return t
    }

    /// 設定が変わったとき。画像トークン数が今の埋め込みと違えば作り直す（索引も作り直しになる）。
    func settingsChanged(imageTokens: Int) {
        guard let active = activeImageTokens, active != imageTokens else { return }
        CCLog.models.notice("image tokens changed \(active) -> \(imageTokens); rebuilding search index")
        activate(imageTokens: imageTokens)
    }

    /// オンボーディングでモデルが揃ったとき。埋め込みが同じ設定で準備済み・準備中なら作り直さず、後回しのステップだけ拾う
    /// （`degraded` のときは `activate` し直して失敗分をやり直す）。
    func modelsPrepared(imageTokens: Int) {
        let usable: [SearchReadiness] = [.ready, .preparing, .rebuilding]
        if usable.contains(readiness), activeImageTokens == imageTokens {
            let queue = queue
            Task {
                do { _ = try await queue.resumePending() } catch {
                    CCLog.models.error("triage resume failed: \(String(describing: error), privacy: .public)")
                }
            }
        } else {
            activate(imageTokens: imageTokens)
        }
    }

    /// テスト用: 実行中の `activate` を待つ。
    func waitForActivation() async {
        await task?.value
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func run(imageTokens: Int, generation gen: Int) async {
        guard let e = makeEmbedder(imageTokens) else {
            activeImageTokens = nil
            await embedder.uninstall()
            readiness = .unavailable
            CCLog.models.notice("embedding model not found; search falls back to substring")
            await resume()
            return
        }
        activeImageTokens = imageTokens
        readiness = .preparing
        // 準備の間もガードと意図は進めてよい（索引ステップは EmbeddingNotReady ですぐ .skipped(.notReady) になり、後で拾われる）。
        await resume()
        let t0 = Date()
        let state = await embedder.install(e)
        guard isCurrent(gen) else { return }
        guard state == .ready else {
            readiness = .failed
            return
        }
        CCLog.models.notice("embedder ready in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1), privacy: .public)s (\(e.indexSignature, privacy: .public))")

        let saved = SearchIndexState.read(from: stateURL)
        if let saved, saved.indexSignature == e.indexSignature {
            if saved.status == .ready {
                readiness = .ready
                await resume()
                return
            }
            if saved.status == .degraded, let failed = saved.failedIDs {
                // 前回の作り直しで索引できなかった記録だけやり直す（全件はやり直さない）。
                CCLog.models.notice("search index: retrying \(failed.count) records that failed last time")
                readiness = .rebuilding
                await resume()
                await finishRebuild(ids: failed, state: saved, generation: gen)
                return
            }
        }

        // 作り直し（初回・シグネチャ変更・前回の作り直しが途中）。
        CCLog.models.notice("search index rebuild: saved=\(saved?.indexSignature ?? "none", privacy: .public)/\(saved?.status.rawValue ?? "-", privacy: .public) new=\(e.indexSignature, privacy: .public)")
        readiness = .rebuilding
        let rebuilding = SearchIndexState(indexSignature: e.indexSignature, imageTokens: imageTokens, dimension: e.dimension,
                                          status: .rebuilding, updatedAt: Date())
        write(rebuilding)
        let ids: [String]
        do {
            let total = try await store.count(InboxFilter(statuses: []))
            ids = total == 0 ? [] : try await store.list(InboxFilter(statuses: [], limit: total)).map(\.id)
        } catch {
            CCLog.models.error("search index rebuild: list failed: \(String(describing: error), privacy: .public)")
            readiness = .failed
            return
        }
        guard isCurrent(gen) else { return }
        // 先に resumePending（埋め込みの無い記録・未処理のガードや意図）を積み、そのあと全件の索引を積む。
        // キューは未着手の同じ id のジョブを 1 つにまとめるので、同じ記録を 2 回埋め込まない。
        await resume()
        // list は新しい順。新しいものから埋め込む（検索で先に見つかってほしいのは最近のもの）。
        await finishRebuild(ids: ids, state: rebuilding, generation: gen)
    }

    /// `ids` の索引を積んで終わるまで待ち、結果で状態を決める。索引できなかった記録が残れば 1 回だけやり直し、
    /// それでも残れば `degraded`（`failed_ids` に残して次回やり直す）。全部できたら `ready`。
    private func finishRebuild(ids: [String], state: SearchIndexState, generation gen: Int) async {
        var failed = await queue.reindexAll(ids: ids)
        guard isCurrent(gen) else { return }
        if !failed.isEmpty {
            CCLog.models.notice("search index: \(failed.count) records failed; retrying once")
            failed = await queue.reindexAll(ids: failed)
            guard isCurrent(gen) else { return }
        }
        var next = state
        next.updatedAt = Date()
        if failed.isEmpty {
            next.status = .ready
            next.failedIDs = nil
            write(next)
            CCLog.models.notice("search index rebuilt: \(ids.count) records")
            readiness = .ready
        } else {
            next.status = .degraded
            next.failedIDs = failed
            write(next)
            CCLog.models.error("search index degraded: \(failed.count) of \(ids.count) records could not be indexed")
            readiness = .degraded(failed: failed.count)
        }
    }

    private func write(_ state: SearchIndexState) {
        do { try state.write(to: stateURL) } catch {
            CCLog.models.error("search index state write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func resume() async {
        do {
            let n = try await queue.resumePending()
            if n > 0 { CCLog.models.notice("triage resumed \(n) records") }
        } catch {
            CCLog.models.error("triage resume failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// 埋め込み検索（F-11）。埋め込みが使えないときは文字の一致（`SubstringSearchService`）で探し、そのことを添える。
struct EmbeddingSearchService: SearchServing {
    let embedder: SwitchableEmbedder
    let store: any RecordStore
    let fallback: SubstringSearchService
    /// 索引の状態（`SearchIndexMaintainer.readiness`）。
    let readiness: @Sendable () async -> SearchReadiness

    static let preparingNotice = "検索の準備中のため、文字の一致で探しています"
    static let unavailableNotice = "検索モデルが未準備のため、文字の一致で探しています"
    static let failedNotice = "見た目での検索を使えないため、文字の一致で探しています"
    static func degradedNotice(failed: Int) -> String {
        "\(failed) 件の記録は索引を作れなかったため、検索に出ないことがあります"
    }

    init(embedder: SwitchableEmbedder, store: any RecordStore, readiness: @escaping @Sendable () async -> SearchReadiness) {
        self.embedder = embedder
        self.store = store
        self.fallback = SubstringSearchService(store: store)
        self.readiness = readiness
    }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        try await searchWithNotice(query, limit: limit).hits
    }

    func searchWithNotice(_ query: String, limit: Int) async throws -> SearchResponse {
        let notice: String
        let current = await readiness()
        switch current {
        case .ready, .degraded:
            // degraded: 大半はこの埋め込みで索引済みなので見た目での検索を使い、出ないことがある旨を添える。
            do {
                let vector = try await embedder.embedQuery(query)
                let hits = try await store.search(vector: vector, limit: limit)
                if case let .degraded(n) = current { return SearchResponse(hits: hits, notice: Self.degradedNotice(failed: n)) }
                return SearchResponse(hits: hits, notice: nil)
            } catch {
                CCLog.models.error("vector search failed, falling back: \(String(describing: type(of: error)), privacy: .public)")
                notice = Self.failedNotice
            }
        case .preparing, .rebuilding: notice = Self.preparingNotice
        case .unavailable: notice = Self.unavailableNotice
        case .failed: notice = Self.failedNotice
        }
        return SearchResponse(hits: try await fallback.search(query, limit: limit), notice: notice)
    }
}
