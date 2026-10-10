import CCCore
import Foundation

/// search_captures が使う埋め込みの解決結果。
public enum QueryEmbedderResolution: Sendable {
    /// 使える（読み込み済み）。
    case available(any Embedder)
    /// 読み込み（温め）中で、待つ上限を過ぎた → 部分一致（`fallback_reason: "embedder_warming"`）。
    case warming
    /// 使えない（モデルが無い・状態ファイルが無い・ready でない・シグネチャ違い）→ `"embedder_unavailable"`。
    case unavailable
    /// 読み込みに失敗した → `"embedder_failed"`（次の検索で読み込みをやり直す）。
    case failed
}

/// 検索のたびに呼ばれ、埋め込みの状態を返す。
public typealias QueryEmbedderResolver = @Sendable () async -> QueryEmbedderResolution

/// cc-mcp の検索用埋め込みの持ち手（Wave 6: 起動直後の温めと、待つ上限つきの解決）。
///
/// - `prewarm()`（起動直後）: 状態ファイル（`SearchIndexState`）が `ready` でシグネチャが合えば、**裏で**読み込みを始める
///   （すぐ戻る。stdio の受付を止めない）。
/// - `resolve()`（検索ごと）: 状態ファイルを読み直す（アプリが作り直しを終えれば次の検索からベクトルを使う）。
///   読み込みが済んでいれば `.available`。読み込み中なら最大 `waitLimit` だけ待ち、間に合わなければ `.warming`
///   （部分一致に切り替え、読み込みは裏で続ける）。
/// - 一度作った埋め込みは**シグネチャ（`Plan.key`）が変わるまで持ち続ける**。アプリの作り直しで状態が一時的に
///   `rebuilding` / `degraded` になっても捨てないので、同じシグネチャで `ready` に戻ったときに読み直さない。
///
/// 埋め込みの作り方（モデルの有無・シグネチャの照合・実際の読み込み）は `decide` が決める（cc-mcp では CoreMLEmbedder の
/// テキスト塔を CPU/GPU で。テストではフェイク）。
public actor WarmingQueryEmbedder {
    /// 状態ファイルに合う埋め込みの作り方。
    public struct Plan: Sendable {
        /// 同じ埋め込みかどうかの鍵（シグネチャ）。変わったら作り直す。
        public var key: String
        public var make: @Sendable () -> any Embedder
        /// 読み込みと初回推論を済ませる（数秒〜数十秒かかりうる）。
        public var warm: @Sendable (any Embedder) async throws -> Void

        public init(key: String, make: @escaping @Sendable () -> any Embedder,
                    warm: @escaping @Sendable (any Embedder) async throws -> Void) {
            self.key = key
            self.make = make
            self.warm = warm
        }
    }

    public enum Decision: Sendable {
        case use(Plan)
        /// 使わない（理由は標準エラーに 1 回だけ出す）。
        case reject(String)
    }

    public static let defaultWaitLimit: Duration = .seconds(5)

    public let stateURL: URL
    public let waitLimit: Duration
    private let decide: @Sendable (SearchIndexState) -> Decision
    private let log: @Sendable (String) -> Void

    private enum Phase { case idle, warming, warm, failed }
    private enum WaitResult { case warm, failed, timeout, superseded }

    private var current: (key: String, embedder: any Embedder)?
    private var phase: Phase = .idle
    private var generation = 0
    private var warmStarted: Date?
    private var waiters: [UUID: CheckedContinuation<WaitResult, Never>] = [:]
    /// 同じ理由の警告を検索のたびに出さない。
    private var lastWarning: String?

    public init(stateURL: URL, waitLimit: Duration = WarmingQueryEmbedder.defaultWaitLimit,
                log: @escaping @Sendable (String) -> Void = { MCPLog.write($0) },
                decide: @escaping @Sendable (SearchIndexState) -> Decision) {
        self.stateURL = stateURL
        self.waitLimit = waitLimit
        self.log = log
        self.decide = decide
    }

    /// 状態が ready なら裏で読み込みを始める（すぐ戻る）。始めた（または済んでいる）なら true。
    @discardableResult
    public func prewarm() -> Bool {
        select() != nil
    }

    /// 検索の直前に呼ぶ。
    public func resolve() async -> QueryEmbedderResolution {
        guard let embedder = select() else { return .unavailable }
        if phase == .warm { return .available(embedder) }
        switch await waitForWarm() {
        case .warm: return .available(embedder)
        case .failed: return .failed
        case .superseded: return .unavailable
        case .timeout:
            log("検索モデルを読み込み中のため部分一致で検索する（\(waitLimit) 待った。読み込みは裏で続ける）")
            return .warming
        }
    }

    /// テスト用: 今の埋め込みが読み込み済みか。
    public var isWarm: Bool { phase == .warm }

    // MARK: - 下請け

    /// 状態ファイルを読み、使う埋め込みを返す（必要なら作って読み込みを始める）。使えなければ nil。
    private func select() -> (any Embedder)? {
        guard let state = SearchIndexState.read(from: stateURL) else {
            warn("索引の状態ファイル（\(SearchIndexState.fileName)）が無いので部分一致で検索する。アプリで検索の準備が終わるのを待ってください")
            return nil
        }
        guard state.status == .ready else {
            // 作り直し中・一部失敗。持っている埋め込みは捨てない（同じシグネチャで ready に戻れば読み直さずに使う）。
            warn("アプリの検索の索引が ready でない（\(state.status)）ので部分一致で検索する")
            return nil
        }
        let plan: Plan
        switch decide(state) {
        case let .reject(message):
            drop()
            warn(message)
            return nil
        case let .use(p):
            plan = p
        }
        if let current, current.key == plan.key {
            if phase == .failed || phase == .idle { startWarm(current.embedder, plan) }
            return current.embedder
        }
        drop()
        let e = plan.make()
        current = (plan.key, e)
        lastWarning = nil
        log("埋め込み検索を使う（\(plan.key)）。テキスト塔の読み込みを裏で始める")
        startWarm(e, plan)
        return e
    }

    private func startWarm(_ embedder: any Embedder, _ plan: Plan) {
        generation += 1
        let gen = generation
        phase = .warming
        warmStarted = Date()
        let warm = plan.warm
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await warm(embedder)
                await self?.warmFinished(generation: gen, ok: true, error: nil)
            } catch {
                await self?.warmFinished(generation: gen, ok: false, error: error)
            }
        }
    }

    private func warmFinished(generation gen: Int, ok: Bool, error: Error?) {
        guard gen == generation else { return }
        phase = ok ? .warm : .failed
        let seconds = warmStarted.map { Date().timeIntervalSince($0) } ?? 0
        if ok {
            log(String(format: "検索モデルの読み込みが済んだ（%.1f 秒）", seconds))
        } else {
            log("検索モデルの読み込みに失敗した（\(error.map { String(describing: type(of: $0)) } ?? "?")）。次の検索でやり直す")
        }
        resumeAll(ok ? .warm : .failed)
    }

    /// 今の埋め込みを捨てる（シグネチャが変わった・使えなくなった）。読み込み待ちは superseded で返す。
    private func drop() {
        guard current != nil else { return }
        generation += 1
        current = nil
        phase = .idle
        resumeAll(.superseded)
    }

    private func waitForWarm() async -> WaitResult {
        let id = UUID()
        let limit = waitLimit
        return await withCheckedContinuation { c in
            // 登録までの間に読み込みが終わっていることがある（ここは actor の上で同期的に走る）。
            switch phase {
            case .warm: return c.resume(returning: .warm)
            case .failed: return c.resume(returning: .failed)
            case .idle: return c.resume(returning: .superseded)
            case .warming: break
            }
            waiters[id] = c
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                await self?.timeOut(id)
            }
        }
    }

    private func timeOut(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .timeout)
    }

    private func resumeAll(_ result: WaitResult) {
        let all = waiters
        waiters = [:]
        for c in all.values { c.resume(returning: result) }
    }

    private func warn(_ message: String) {
        guard message != lastWarning else { return }
        lastWarning = message
        log(message)
    }
}
