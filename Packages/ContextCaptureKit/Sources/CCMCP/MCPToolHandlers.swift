import CCCore
import CCStore
import Foundation
import MCP

/// 埋め込みモデルを返す関数。初回の検索で呼ばれる（遅延ロードは提供側の責任）。使えなければ nil。
public typealias EmbedderProvider = @Sendable () async -> (any Embedder)?

/// 6 ツールの処理。トランスポートから切り離した純粋なハンドラ（テストは `call` を直接呼ぶ）。
///
/// エラーの返し方:
/// - 入力がスキーマに合わない（必須欠落・型違い・範囲外・ULID でない・未知のツール）→ `MCPError.invalidParams` を投げる
/// - 入力は正しいが対象が無い（id の記録が無い）・ストアの失敗 → `isError: true` のツール結果
public struct MCPToolHandlers: Sendable {
    public let store: SQLiteRecordStore
    public let embedderProvider: EmbedderProvider
    /// 検索ごとに埋め込みの状態を引く（読み込み中を区別できる。cc-mcp は `WarmingQueryEmbedder.resolve`）。
    public let embedderResolver: QueryEmbedderResolver
    public let imageLoader: MCPImageLoader
    /// 日付だけの since と Markdown の時刻のタイムゾーン、JSON の日時のオフセット。
    public let timeZone: TimeZone
    /// 現在時刻（テストで固定する）。
    public let now: @Sendable () -> Date

    /// keyword 検索で走査する記録数の上限（新しい順）。
    public var keywordScanLimit = 5000

    public init(
        store: SQLiteRecordStore,
        embedderProvider: @escaping EmbedderProvider = { nil },
        imageLoader: MCPImageLoader = MCPImageLoader(),
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.embedderProvider = embedderProvider
        self.embedderResolver = {
            if let e = await embedderProvider() { return .available(e) }
            return .unavailable
        }
        self.imageLoader = imageLoader
        self.timeZone = timeZone
        self.now = now
    }

    /// 読み込み中（`.warming`）を区別できる解決関数で作る（cc-mcp はこちら）。
    public init(
        store: SQLiteRecordStore,
        embedderResolver: @escaping QueryEmbedderResolver,
        imageLoader: MCPImageLoader = MCPImageLoader(),
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.embedderResolver = embedderResolver
        self.embedderProvider = {
            if case let .available(e) = await embedderResolver() { return e }
            return nil
        }
        self.imageLoader = imageLoader
        self.timeZone = timeZone
        self.now = now
    }

    /// 既定のクライアント名（initialize の clientInfo が無い・空のとき）。
    public static let unknownClientName = "mcp-client"

    /// クライアント名を note の author / handoff の to に使える形にする（制御文字を除き 64 文字まで）。
    public static func sanitizeClientName(_ raw: String?) -> String {
        let cleaned = (raw ?? "")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? unknownClientName : String(cleaned.prefix(64))
    }

    /// ツールを 1 回呼ぶ。`clientName` は initialize の clientInfo.name。
    public func call(name: String, arguments: [String: Value]?, clientName: String?) async throws -> CallTool.Result {
        guard let tool = CCMCPToolName(rawValue: name) else {
            throw MCPError.invalidParams("未知のツール: \(name)")
        }
        let client = Self.sanitizeClientName(clientName)
        switch tool {
        case .listInbox:
            return try await listInbox(MCPArguments(tool: tool, arguments, allowed: ["since", "intent", "limit"]))
        case .searchCaptures:
            return try await searchCaptures(MCPArguments(tool: tool, arguments, allowed: ["query", "limit", "include_archived"]))
        case .getCapture:
            return try await getCapture(MCPArguments(tool: tool, arguments, allowed: ["id", "include_image"]), client: client)
        case .addNote:
            return try await addNote(MCPArguments(tool: tool, arguments, allowed: ["id", "text"]), client: client)
        case .markDone:
            return try await setStatus(MCPArguments(tool: tool, arguments, allowed: ["id"]), .done)
        case .archive:
            return try await setStatus(MCPArguments(tool: tool, arguments, allowed: ["id"]), .archived)
        }
    }

    // MARK: - list_inbox

    func listInbox(_ args: MCPArguments) async throws -> CallTool.Result {
        let since = try args.date("since", timeZone: timeZone)
        let limit = try args.int("limit", range: 1...CCMCPToolCatalog.maxLimit) ?? CCMCPToolCatalog.defaultListLimit
        var filter = InboxFilter(statuses: [.inbox], since: since, limit: limit)
        if let intentRaw = try args.string("intent") {
            if intentRaw == "unclassified" {
                filter.unclassifiedOnly = true
            } else if let intent = Intent(rawValue: intentRaw) {
                filter.intent = intent
            } else {
                throw args.invalid("intent は \(CCMCPToolCatalog.intentFilterValues.joined(separator: " / ")) のどれか")
            }
        }
        return try await storeOperation {
            let records = try await store.list(filter)
            let total = try await store.count(filter)
            return try jsonResult(ListInboxOutput(count: records.count, total: total, items: records.map { CaptureSummary($0) }))
        }
    }

    // MARK: - search_captures

    func searchCaptures(_ args: MCPArguments) async throws -> CallTool.Result {
        guard let query = try args.string("query", required: true, maxLength: CCMCPToolCatalog.maxQueryLength) else {
            throw args.invalid("query は必須")
        }
        let limit = try args.int("limit", range: 1...CCMCPToolCatalog.maxLimit) ?? CCMCPToolCatalog.defaultSearchLimit
        let includeArchived = try args.bool("include_archived") ?? false
        let statuses = Self.searchStatuses(includeArchived: includeArchived)

        return try await storeOperation {
            let fallbackReason: String
            switch await embedderResolver() {
            case .unavailable:
                fallbackReason = "embedder_unavailable"
            case .warming:
                fallbackReason = "embedder_warming"
            case .failed:
                fallbackReason = "embedder_failed"
            case let .available(embedder):
                do {
                    let signed = try await (embedder as? any SignatureReportingEmbedder)?.embedQueryWithSignature(query)
                    let vector: [Float]
                    if let signed { vector = signed.vector } else { vector = try await embedder.embedQuery(query) }
                    // 状態の絞り込みは上位 limit 件を選ぶ前に効く（archived が多くても件数が足りなくならない）。
                    let hits: [SearchHit]
                    if let signed {
                        hits = try await store.search(vector: vector, limit: limit, statuses: statuses, compatibilityKey: signed.compatibilityKey)
                    } else {
                        // Legacy fakes/fixtures have no generation descriptor.
                        hits = try await store.search(vector: vector, limit: limit, statuses: statuses)
                    }
                    let items = hits.map { CaptureSummary($0.record, score: $0.score) }
                    return try jsonResult(SearchOutput(mode: "vector", fallbackReason: nil, query: query, count: items.count, items: items))
                } catch {
                    fallbackReason = "embedder_failed"
                    MCPLog.write("search_captures: 埋め込み検索に失敗したので部分一致に切り替える（\(type(of: error))）")
                }
            }
            let records = try await keywordSearch(query: query, limit: limit, includeArchived: includeArchived)
            return try jsonResult(SearchOutput(
                mode: "keyword", fallbackReason: fallbackReason, query: query,
                count: records.count, items: records.map { CaptureSummary($0) }
            ))
        }
    }

    /// 注釈・ウインドウタイトル・URL の部分一致（空白区切りの語をすべて含む。大小・全角半角・濁点の有無を区別しない）。新しい順。
    func keywordSearch(query: String, limit: Int, includeArchived: Bool) async throws -> [ContextRecord] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let statuses = Self.searchStatuses(includeArchived: includeArchived)
        var results: [ContextRecord] = []
        var offset = 0
        let page = 500
        while results.count < limit, offset < keywordScanLimit {
            let batch = try await store.list(InboxFilter(statuses: statuses, limit: page, offset: offset))
            for r in batch where Self.matches(r, terms: terms) {
                results.append(r)
                if results.count == limit { break }
            }
            if batch.count < page { break }
            offset += page
        }
        return results
    }

    /// 検索の対象にする状態（空集合は全状態）。archived は `include_archived` のときだけ。
    static func searchStatuses(includeArchived: Bool) -> Set<RecordStatus> {
        includeArchived ? [] : [.inbox, .done]
    }

    static func matches(_ r: ContextRecord, terms: [String]) -> Bool {
        let haystack = [r.annotation.text, r.window?.title ?? "", r.url ?? "", r.app.name].joined(separator: "\n")
        let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]
        return terms.allSatisfy { haystack.range(of: $0, options: options) != nil }
    }

    // MARK: - get_capture

    func getCapture(_ args: MCPArguments, client: String) async throws -> CallTool.Result {
        let id = try args.id()
        let includeImage = try args.bool("include_image") ?? false
        return try await storeOperation {
            guard var record = try await store.get(id: id) else { return notFound(id) }

            var image: MCPImageLoader.LoadedImage?
            var omitted: String?
            if includeImage {
                switch Self.imageDecision(record) {
                case let .deny(reason):
                    omitted = reason
                case let .allow(relativePath):
                    do {
                        image = try imageLoader.load(relativePath: relativePath, paths: store.paths)
                    } catch MCPImageLoader.LoadError.outsideDataRoot {
                        omitted = "画像のパスが不正なため渡せません"
                        MCPLog.write("get_capture: データルート外を指す添付パスを拒否した")
                    } catch MCPImageLoader.LoadError.notFound {
                        omitted = "画像ファイルが見つからないため渡せません（保持期間で削除された可能性があります）"
                    } catch {
                        omitted = "画像を読み込めないため渡せません"
                    }
                }
            }
            if image != nil {
                // 実際に画像を渡したときだけ受け渡しを記録する。
                record = try await store.appendHandoff(id: id, Handoff(to: client, at: now().roundedToMilliseconds, via: "mcp"))
            }

            let detail = CaptureDetail(record, imageIncluded: image != nil, imageOmittedReason: omitted)
            var content: [Tool.Content] = [
                .text(text: try encodeJSON(detail), annotations: nil, _meta: nil),
                .text(text: RecordMarkdown.render(record, includeScreenshotLink: false, timeZone: timeZone), annotations: nil, _meta: nil),
            ]
            if let image {
                content.append(.image(data: image.data.base64EncodedString(), mimeType: image.mimeType, annotations: nil, _meta: nil))
            } else if let omitted {
                content.append(.text(text: omitted, annotations: nil, _meta: nil))
            }
            return CallTool.Result(content: content, isError: false)
        }
    }

    /// 画像を渡してよいか（規則は `RecordMarkdown.handoffScreenshotPath` と共有）。
    enum ImageDecision: Equatable {
        case allow(relativePath: String)
        case deny(reason: String)
    }

    static func imageDecision(_ record: ContextRecord) -> ImageDecision {
        if let path = RecordMarkdown.handoffScreenshotPath(record) { return .allow(relativePath: path) }
        if record.screenshotPath == nil, record.maskedScreenshotPath == nil {
            return .deny(reason: "この記録にはスクショがありません")
        }
        switch record.guardInfo.status {
        case .needsReview:
            return .deny(reason: "秘密情報の確認待ちのため画像は渡せません（ユーザーがアプリの Inbox で確認すると渡せるようになります）")
        case .pending:
            return .deny(reason: "秘密情報のチェックがまだ済んでいないため画像は渡せません")
        case .masked:
            return .deny(reason: "マスク版の画像がまだ無いため画像は渡せません")
        case .clear:
            return .deny(reason: "この記録にはスクショがありません")
        }
    }

    // MARK: - add_note / mark_done / archive

    func addNote(_ args: MCPArguments, client: String) async throws -> CallTool.Result {
        let id = try args.id()
        guard let text = try args.string("text", required: true, maxLength: CCMCPToolCatalog.maxNoteLength) else {
            throw args.invalid("text は必須")
        }
        let note = Note(author: client, text: text, at: now().roundedToMilliseconds)
        return try await storeOperation {
            do {
                let record = try await store.appendNote(id: id, note: note)
                return try jsonResult(AddNoteOutput(
                    id: id, notesCount: record.notes.count,
                    note: .init(author: note.author, text: note.text, at: note.at)
                ))
            } catch CCStoreError.notFound {
                return notFound(id)
            }
        }
    }

    func setStatus(_ args: MCPArguments, _ status: RecordStatus) async throws -> CallTool.Result {
        let id = try args.id()
        return try await storeOperation {
            guard let before = try await store.get(id: id) else { return notFound(id) }
            do {
                let record = try await store.setStatus(id: id, status)
                return try jsonResult(StatusOutput(id: id, status: record.status.rawValue, previousStatus: before.status.rawValue))
            } catch CCStoreError.notFound {
                return notFound(id)
            }
        }
    }

    // MARK: - 共通

    func notFound(_ id: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: "記録が見つかりません: \(id)", annotations: nil, _meta: nil)], isError: true)
    }

    /// ストア操作の失敗を isError の結果にする（MCPError はそのまま投げる）。
    func storeOperation(_ body: () async throws -> CallTool.Result) async throws -> CallTool.Result {
        do {
            return try await body()
        } catch let error as MCPError {
            throw error
        } catch {
            MCPLog.write("ストア操作に失敗: \(type(of: error))")
            return CallTool.Result(
                content: [.text(text: "記録の読み書きに失敗しました（\(type(of: error))）", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try CCJSON.encoder(timeZone: timeZone).encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    func jsonResult<T: Encodable>(_ value: T) throws -> CallTool.Result {
        CallTool.Result(content: [.text(text: try encodeJSON(value), annotations: nil, _meta: nil)], isError: false)
    }
}

/// 標準エラーへの短いログ（標準出力は MCP のプロトコル専用）。秘密や注釈本文は渡さないこと。
public enum MCPLog {
    public static func write(_ message: String) {
        FileHandle.standardError.write(Data("[cc-mcp] \(message)\n".utf8))
    }
}
