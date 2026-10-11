import CCCore
import CCStore
import Foundation
import MCP
import UniformTypeIdentifiers
import XCTest
@testable import CCMCP

final class MCPToolHandlersTests: XCTestCase {
    var temp: TempStore!
    var handlers: MCPToolHandlers!
    let fixedNow = Date(timeIntervalSince1970: 1_791_600_000)

    override func setUpWithError() throws {
        temp = try TempStore()
        let now = fixedNow
        handlers = MCPToolHandlers(store: temp.store, timeZone: Fixtures.tokyo, now: { now })
    }

    override func tearDown() {
        handlers = nil
        temp = nil
    }

    func call(_ name: String, _ args: [String: Value]? = nil, client: String? = "claude-code") async throws -> CallTool.Result {
        try await handlers.call(name: name, arguments: args, clientName: client)
    }

    /// 画像付きの記録を保存する。
    @discardableResult
    func insertWithImages(_ record: ContextRecord, screenshot: Bool = true, masked: Bool = false) async throws -> ContextRecord {
        var r = record
        if screenshot {
            r.screenshotPath = try await temp.store.writeAttachment(Fixtures.imageData(type: .png), id: r.id, kind: .screenshot, ext: "png", capturedAt: r.capturedAt)
        }
        if masked {
            r.maskedScreenshotPath = try await temp.store.writeAttachment(Fixtures.imageData(width: 32, height: 24, type: .jpeg), id: r.id, kind: .maskedScreenshot, ext: "jpg", capturedAt: r.capturedAt)
        }
        try await temp.store.insert(r)
        return r
    }

    // MARK: - カタログ

    func testCatalogHasExactlySixToolsAndNoDeleteTool() {
        let names = CCMCPToolCatalog.tools.map(\.name)
        XCTAssertEqual(names, ["list_inbox", "search_captures", "get_capture", "add_note", "mark_done", "archive"])
        XCTAssertFalse(names.contains { $0.contains("delete") || $0.contains("remove") || $0.contains("purge") })
        XCTAssertTrue(CCMCPToolCatalog.tools.allSatisfy { $0.annotations.destructiveHint == false })
    }

    func testDeleteToolIsRejectedAndRecordSurvives() async throws {
        let r = Fixtures.record("消さないで")
        try await temp.store.insert(r)
        for name in ["delete", "delete_capture", "remove"] {
            await assertInvalidParams(try await call(name, ["id": .string(r.id)]), "未知のツール")
        }
        let stillThere = try await temp.store.get(id: r.id)
        XCTAssertNotNil(stillThere)
    }

    func testSchemasDeclareRequiredTypesAndLimits() throws {
        let byName = Dictionary(uniqueKeysWithValues: CCMCPToolCatalog.tools.map { ($0.name, $0.inputSchema) })
        let list = try XCTUnwrap(byName["list_inbox"]?.objectValue)
        let listProps = try XCTUnwrap(list["properties"]?.objectValue)
        XCTAssertEqual(listProps["limit"]?.objectValue?["maximum"], .int(50))
        XCTAssertEqual(listProps["limit"]?.objectValue?["type"], .string("integer"))
        XCTAssertEqual(listProps["since"]?.objectValue?["format"], .string("date-time"))
        XCTAssertEqual(listProps["intent"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue),
                       ["todo", "research", "code", "note", "schedule", "unclassified"])
        XCTAssertNil(list["required"])
        XCTAssertEqual(byName["search_captures"]?.objectValue?["required"], ["query"])
        XCTAssertEqual(byName["get_capture"]?.objectValue?["required"], ["id"])
        XCTAssertEqual(byName["add_note"]?.objectValue?["required"], ["id", "text"])
        XCTAssertEqual(byName["mark_done"]?.objectValue?["required"], ["id"])
        XCTAssertEqual(byName["archive"]?.objectValue?["required"], ["id"])
        for (_, schema) in byName {
            XCTAssertEqual(schema.objectValue?["type"], .string("object"))
            XCTAssertEqual(schema.objectValue?["additionalProperties"], .bool(false))
        }
    }

    // MARK: - list_inbox

    func testListInboxReturnsInboxOnlyNewestFirstWithFields() async throws {
        let base = Date(timeIntervalSince1970: 1_791_500_000)
        let old = Fixtures.record("古い", at: base, url: "https://example.com/a")
        let new = Fixtures.record("新しい", at: base.addingTimeInterval(60), intent: nil, confidence: 0.42, guardStatus: .needsReview)
        let done = Fixtures.record("済み", at: base.addingTimeInterval(120), status: .done)
        let archived = Fixtures.record("しまった", at: base.addingTimeInterval(180), status: .archived)
        try await insertWithImages(old)
        try await insertWithImages(new)
        try await temp.store.insert(done)
        try await temp.store.insert(archived)

        let json = try await call("list_inbox").json()
        XCTAssertEqual(json["count"] as? Int, 2)
        XCTAssertEqual(json["total"] as? Int, 2)
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["id"] as? String }, [new.id, old.id])

        let first = items[0]
        XCTAssertEqual(first["annotation"] as? String, "新しい")
        XCTAssertTrue(first["intent"] is NSNull, "未分類は null")
        XCTAssertEqual(first["intent_unclassified"] as? Bool, true)
        XCTAssertEqual(first["intent_confidence"] as? Double, 0.42)
        XCTAssertEqual(first["guard_status"] as? String, "needs_review")
        XCTAssertEqual(first["has_screenshot"] as? Bool, true)
        XCTAssertEqual(first["image_available"] as? Bool, false)
        XCTAssertEqual(first["app"] as? String, "Visual Studio Code")
        XCTAssertEqual(first["window_title"] as? String, "adapter.ts — mach-runtime")
        XCTAssertEqual(first["mentions_datetime"] as? Bool, false)
        XCTAssertEqual(first["captured_at"] as? String, "2026-10-09T07:54:20+09:00")

        let second = items[1]
        XCTAssertEqual(second["intent"] as? String, "code")
        XCTAssertEqual(second["url"] as? String, "https://example.com/a")
        XCTAssertEqual(second["image_available"] as? Bool, true)
        XCTAssertNil(second["screenshot"], "添付パスは出さない")
    }

    func testListInboxFilters() async throws {
        let base = Date(timeIntervalSince1970: 1_791_500_000)  // 2026-10-09T07:53:20+09:00
        try await temp.store.insert(Fixtures.record("code 古い", at: base.addingTimeInterval(-86_400)))
        try await temp.store.insert(Fixtures.record("code 新しい", at: base))
        try await temp.store.insert(Fixtures.record("todo", at: base, intent: .todo))
        try await temp.store.insert(Fixtures.record("未分類", at: base, intent: nil, confidence: 0.3))
        try await temp.store.insert(Fixtures.record("未トリアージ", at: base, triaged: false))

        var json = try await call("list_inbox", ["intent": "code"]).json()
        XCTAssertEqual(json["count"] as? Int, 2)

        json = try await call("list_inbox", ["intent": "code", "since": "2026-10-09T00:00:00+09:00"]).json()
        XCTAssertEqual((json["items"] as? [[String: Any]])?.map { $0["annotation"] as? String }, ["code 新しい"])

        json = try await call("list_inbox", ["since": "2026-10-09"]).json()  // 日付だけ = 東京の 0 時
        XCTAssertEqual(json["count"] as? Int, 4)

        json = try await call("list_inbox", ["intent": "unclassified"]).json()
        XCTAssertEqual((json["items"] as? [[String: Any]])?.map { $0["annotation"] as? String }, ["未分類"])

        json = try await call("list_inbox", ["limit": 2]).json()
        XCTAssertEqual(json["count"] as? Int, 2)
        XCTAssertEqual(json["total"] as? Int, 5)

        json = try await call("list_inbox", ["limit": .double(3.0), "intent": .null]).json()
        XCTAssertEqual(json["count"] as? Int, 3)

        let untriaged = try await call("list_inbox", ["limit": 50]).json()["items"] as? [[String: Any]]
        let item = try XCTUnwrap(untriaged?.first { $0["annotation"] as? String == "未トリアージ" })
        XCTAssertEqual(item["triaged"] as? Bool, false)
        XCTAssertTrue(item["intent_unclassified"] is NSNull)
    }

    func testListInboxValidation() async throws {
        await assertInvalidParams(try await call("list_inbox", ["limit": 0]), "limit")
        await assertInvalidParams(try await call("list_inbox", ["limit": 51]), "limit")
        await assertInvalidParams(try await call("list_inbox", ["limit": .double(2.5)]), "limit")
        await assertInvalidParams(try await call("list_inbox", ["limit": "10"]), "limit")
        await assertInvalidParams(try await call("list_inbox", ["intent": "shopping"]), "intent")
        await assertInvalidParams(try await call("list_inbox", ["since": "昨日"]), "since")
        await assertInvalidParams(try await call("list_inbox", ["since": "2026-13-45"]), "since")
        await assertInvalidParams(try await call("list_inbox", ["status": "done"]), "未知の引数")
    }

    // MARK: - search_captures

    func testSearchUsesEmbedderAndExcludesArchived() async throws {
        let a = Fixtures.record("alpha の件")
        let b = Fixtures.record("beta の件")
        let archived = Fixtures.record("alpha アーカイブ済み", status: .archived)
        let embedder = FakeEmbedder()
        for r in [a, b, archived] {
            try await temp.store.insert(r)
            try await temp.store.setEmbedding(id: r.id, vector: embedder.vector(for: r.annotation.text))
        }
        handlers = MCPToolHandlers(store: temp.store, embedderProvider: { embedder }, timeZone: Fixtures.tokyo)

        var json = try await call("search_captures", ["query": "alpha"]).json()
        XCTAssertEqual(json["mode"] as? String, "vector")
        XCTAssertTrue(json["fallback_reason"] is NSNull)
        var items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["id"] as? String, a.id)
        XCTAssertFalse(items.contains { $0["id"] as? String == archived.id })
        XCTAssertNotNil(items.first?["score"] as? Double)

        json = try await call("search_captures", ["query": "alpha", "include_archived": true, "limit": 2]).json()
        items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(Set(items.compactMap { $0["id"] as? String }), [a.id, archived.id])
    }

    /// archived が上位を占めても、状態の絞り込みが上位 limit 件を選ぶ前に効くので件数が足りる
    /// （以前は limit*4+20 件取ってから archived を落としていたので、この条件で 0 件になった）。
    func testVectorSearchFiltersStatusesBeforeLimit() async throws {
        let embedder = FakeEmbedder()
        // 「alpha」に完全一致する archived を 30 件、少しずれる inbox / done を 1 件ずつ。
        for i in 0..<30 {
            let r = Fixtures.record("alpha archived \(i)", at: Date(timeIntervalSince1970: 1_791_500_000 + Double(i)), status: .archived)
            try await temp.store.insert(r)
            try await temp.store.setEmbedding(id: r.id, vector: embedder.vector(for: "alpha"))
        }
        let inbox = Fixtures.record("alpha beta inbox", at: Date(timeIntervalSince1970: 1_791_400_000))
        let done = Fixtures.record("alpha gamma done", at: Date(timeIntervalSince1970: 1_791_400_001), status: .done)
        for r in [inbox, done] {
            try await temp.store.insert(r)
            try await temp.store.setEmbedding(id: r.id, vector: embedder.vector(for: r.annotation.text))
        }
        handlers = MCPToolHandlers(store: temp.store, embedderProvider: { embedder }, timeZone: Fixtures.tokyo)

        var json = try await call("search_captures", ["query": "alpha", "limit": 2]).json()
        XCTAssertEqual(json["mode"] as? String, "vector")
        var items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(Set(items.compactMap { $0["id"] as? String }), [inbox.id, done.id])

        json = try await call("search_captures", ["query": "alpha", "limit": 5, "include_archived": true]).json()
        items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(items.allSatisfy { $0["status"] as? String == "archived" })
    }

    func testSearchFallsBackToKeywordWithoutEmbedder() async throws {
        try await temp.store.insert(Fixtures.record("ここで null になる理由を調べて", title: "adapter.ts"))
        try await temp.store.insert(Fixtures.record("買い物リスト", title: "メモ", url: "https://shop.example.com/Cart"))
        try await temp.store.insert(Fixtures.record("null アーカイブ", status: .archived))
        try await temp.store.insert(Fixtures.record("null 済み", status: .done))

        var json = try await call("search_captures", ["query": "NULL"]).json()
        XCTAssertEqual(json["mode"] as? String, "keyword")
        XCTAssertEqual(json["fallback_reason"] as? String, "embedder_unavailable")
        XCTAssertEqual(Set((json["items"] as? [[String: Any]])?.compactMap { $0["annotation"] as? String } ?? []),
                       ["ここで null になる理由を調べて", "null 済み"])

        json = try await call("search_captures", ["query": "shop.example cart"]).json()  // URL・大文字小文字・複数語
        XCTAssertEqual((json["items"] as? [[String: Any]])?.count, 1)

        json = try await call("search_captures", ["query": "adapter 理由"]).json()  // タイトル + 注釈
        XCTAssertEqual((json["items"] as? [[String: Any]])?.count, 1)

        json = try await call("search_captures", ["query": "存在しない語"]).json()
        XCTAssertEqual(json["count"] as? Int, 0)
    }

    func testSearchFallsBackWhenEmbedderFails() async throws {
        try await temp.store.insert(Fixtures.record("gamma の調査"))
        handlers = MCPToolHandlers(store: temp.store, embedderProvider: { FakeEmbedder(fail: true) })
        var json = try await call("search_captures", ["query": "gamma"]).json()
        XCTAssertEqual(json["mode"] as? String, "keyword")
        XCTAssertEqual(json["fallback_reason"] as? String, "embedder_failed")
        XCTAssertEqual(json["count"] as? Int, 1)

        // 次元違い（store.search が dimensionMismatch を投げる）も部分一致へ。
        handlers = MCPToolHandlers(store: temp.store, embedderProvider: { FakeEmbedder(dimension: 8) })
        json = try await call("search_captures", ["query": "gamma"]).json()
        XCTAssertEqual(json["mode"] as? String, "keyword")
        XCTAssertEqual(json["fallback_reason"] as? String, "embedder_failed")
    }

    func testSearchValidation() async throws {
        await assertInvalidParams(try await call("search_captures"), "query")
        await assertInvalidParams(try await call("search_captures", ["query": "   "]), "query")
        await assertInvalidParams(try await call("search_captures", ["query": 3]), "query")
        await assertInvalidParams(try await call("search_captures", ["query": .string(String(repeating: "あ", count: 1001))]), "query")
        await assertInvalidParams(try await call("search_captures", ["query": "x", "limit": 100]), "limit")
        await assertInvalidParams(try await call("search_captures", ["query": "x", "include_archived": "yes"]), "include_archived")
    }

    // MARK: - get_capture と画像の規則

    func testGetCaptureClearReturnsOriginalImageAndRecordsHandoff() async throws {
        let r = try await insertWithImages(Fixtures.record("clear の件", guardStatus: .clear), masked: true)
        let result = try await call("get_capture", ["id": .string(r.id), "include_image": true])
        XCTAssertEqual(result.isError, false)
        let image = try XCTUnwrap(result.images.first)
        XCTAssertEqual(image.mimeType, "image/png")
        let original = try Data(contentsOf: temp.paths.url(forRelativePath: r.screenshotPath!))
        XCTAssertEqual(Data(base64Encoded: image.data), original, "clear は元画像")

        let json = try result.json()
        XCTAssertEqual(json["image_included"] as? Bool, true)
        XCTAssertEqual(json["id"] as? String, r.id)
        XCTAssertTrue(result.texts[1].hasPrefix("## 2026-10-09 07:53 · Visual Studio Code"), "2 つ目は Markdown")
        XCTAssertFalse(result.texts[1].contains("captures/"), "Markdown にパスを出さない")

        let stored = try await temp.store.get(id: r.id)
        XCTAssertEqual(stored?.handoffs, [Handoff(to: "claude-code", at: fixedNow, via: "mcp")])
        XCTAssertEqual((json["handoffs"] as? [[String: Any]])?.first?["to"] as? String, "claude-code")
    }

    func testGetCaptureMaskedReturnsMaskedVersion() async throws {
        let r = try await insertWithImages(Fixtures.record("masked の件", guardStatus: .masked), masked: true)
        let result = try await call("get_capture", ["id": .string(r.id), "include_image": true], client: "hermes")
        let image = try XCTUnwrap(result.images.first)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        let masked = try Data(contentsOf: temp.paths.url(forRelativePath: r.maskedScreenshotPath!))
        XCTAssertEqual(Data(base64Encoded: image.data), masked, "masked はマスク版")
        let stored = try await temp.store.get(id: r.id)
        XCTAssertEqual(stored?.handoffs.map(\.to), ["hermes"])
        XCTAssertEqual(try result.json()["guard_finding_kinds"] as? [String], ["github_token"])
    }

    func testGetCaptureNeverReturnsNeedsReviewOrPendingImages() async throws {
        for status in [GuardStatus.needsReview, .pending] {
            // マスク版のファイルがあっても返さない。
            let r = try await insertWithImages(Fixtures.record("\(status.rawValue) の件", guardStatus: status), masked: true)
            let result = try await call("get_capture", ["id": .string(r.id), "include_image": true])
            XCTAssertEqual(result.isError, false)
            XCTAssertTrue(result.images.isEmpty, "\(status) の画像は返さない")
            let json = try result.json()
            XCTAssertEqual(json["image_included"] as? Bool, false)
            XCTAssertEqual(json["image_available"] as? Bool, false)
            let reason = try XCTUnwrap(json["image_omitted_reason"] as? String)
            XCTAssertTrue(reason.contains(status == .needsReview ? "確認待ち" : "チェック"), reason)
            XCTAssertEqual(result.texts.last, reason)
            let stored = try await temp.store.get(id: r.id)
            XCTAssertEqual(stored?.handoffs, [], "画像を渡していないので handoff は記録しない")
        }
    }

    func testGetCaptureWithoutImageRequestAndWithoutScreenshot() async throws {
        let r = try await insertWithImages(Fixtures.record("clear"))
        var result = try await call("get_capture", ["id": .string(r.id)])
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(result.texts.count, 2)
        XCTAssertTrue(try result.json()["image_omitted_reason"] == nil)
        var stored = try await temp.store.get(id: r.id)
        XCTAssertEqual(stored?.handoffs, [])

        let noShot = Fixtures.record("スクショ無し")
        try await temp.store.insert(noShot)
        result = try await call("get_capture", ["id": .string(noShot.id), "include_image": true])
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(try result.json()["image_omitted_reason"] as? String, "この記録にはスクショがありません")
        stored = try await temp.store.get(id: noShot.id)
        XCTAssertEqual(stored?.handoffs, [])
    }

    func testGetCaptureRefusesTraversalAndOutsidePaths() async throws {
        // データルート外に「秘密」ファイルを置く。
        let secret = temp.root.appendingPathComponent("secret.png")
        try Fixtures.imageData().write(to: secret)

        let badPaths = ["../secret.png", "/etc/hosts", secret.path, "captures/../../secret.png", "~/secret.png", "captures/./x.png", ""]
        for bad in badPaths {
            var r = Fixtures.record("不正なパス")
            r.screenshotPath = bad
            try await temp.store.insert(r)
            let result = try await call("get_capture", ["id": .string(r.id), "include_image": true])
            XCTAssertTrue(result.images.isEmpty, "\(bad) を読んではいけない")
            XCTAssertEqual(try result.json()["image_omitted_reason"] as? String, "画像のパスが不正なため渡せません", bad)
            XCTAssertFalse(result.texts.joined().contains(secret.path), "パスを応答に出さない")
            let stored = try await temp.store.get(id: r.id)
            XCTAssertEqual(stored?.handoffs, [])
        }

        // データルート内のシンボリックリンクがルート外を指すときも読まない。
        var linked = Fixtures.record("symlink")
        let rel = "captures/2026/10/09/\(linked.id).png"
        let linkURL = try temp.paths.url(forRelativePath: rel)
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: secret)
        linked.screenshotPath = rel
        try await temp.store.insert(linked)
        let result = try await call("get_capture", ["id": .string(linked.id), "include_image": true])
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(try result.json()["image_omitted_reason"] as? String, "画像のパスが不正なため渡せません")
    }

    func testGetCaptureMissingFileIsReportedWithoutHandoff() async throws {
        var r = Fixtures.record("消えた画像")
        r.screenshotPath = "captures/2026/10/09/\(r.id).png"
        try await temp.store.insert(r)
        let result = try await call("get_capture", ["id": .string(r.id), "include_image": true])
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertTrue((try result.json()["image_omitted_reason"] as? String)?.contains("見つからない") == true)
        let stored = try await temp.store.get(id: r.id)
        XCTAssertEqual(stored?.handoffs, [])
    }

    func testLargeImageIsDownscaled() async throws {
        var r = Fixtures.record("大きい画像")
        let big = Fixtures.imageData(width: 1200, height: 900, type: .png, noise: true)
        r.screenshotPath = try await temp.store.writeAttachment(big, id: r.id, kind: .screenshot, ext: "png", capturedAt: r.capturedAt)
        try await temp.store.insert(r)
        let limit = 200_000
        XCTAssertGreaterThan(big.count, limit)
        handlers = MCPToolHandlers(store: temp.store, imageLoader: MCPImageLoader(maxBytes: limit, maxPixelSize: 800))
        let result = try await call("get_capture", ["id": .string(r.id), "include_image": true])
        let image = try XCTUnwrap(result.images.first)
        XCTAssertEqual(image.mimeType, "image/jpeg", "縮小したら出力形式（JPEG）の MIME")
        let data = try XCTUnwrap(Data(base64Encoded: image.data))
        XCTAssertLessThanOrEqual(data.count, limit)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertLessThanOrEqual(props?[kCGImagePropertyPixelWidth] as? Int ?? .max, 800)
    }

    // MARK: - HEIC（本番の保存形式）

    /// 本番と同じく元画像とマスク版を HEIC で保存した記録。
    @discardableResult
    func insertWithHEIC(_ record: ContextRecord, width: Int = 400, height: Int = 300) async throws -> ContextRecord {
        var r = record
        let original = try HEICFixtures.encode(HEICFixtures.image(width: width, height: height))
        r.screenshotPath = try await temp.store.writeAttachment(original, id: r.id, kind: .screenshot, ext: "heic", capturedAt: r.capturedAt)
        let masked = try HEICFixtures.encode(HEICFixtures.image(width: width, height: height, blackFraction: 0.5))
        r.maskedScreenshotPath = try await temp.store.writeAttachment(masked, id: r.id, kind: .maskedScreenshot, ext: "heic", capturedAt: r.capturedAt)
        try await temp.store.insert(r)
        return r
    }

    func decodeImage(_ base64: String) throws -> CGImage {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.jpeg.identifier, "中身も JPEG")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// clear の HEIC は JPEG に変換して返す（MCP クライアントが HEIC を読めるとは限らない）。
    func testHEICClearIsReturnedAsJPEG() async throws {
        let r = try await insertWithHEIC(Fixtures.record("HEIC の clear", guardStatus: .clear))
        let result = try await call("get_capture", ["id": .string(r.id), "include_image": true])
        XCTAssertEqual(result.isError, false)
        let image = try XCTUnwrap(result.images.first, "HEIC でも画像を返す")
        XCTAssertEqual(image.mimeType, "image/jpeg")
        let decoded = try decodeImage(image.data)
        XCTAssertEqual(decoded.width, 400)
        XCTAssertEqual(decoded.height, 300)
        XCTAssertEqual(try result.json()["image_included"] as? Bool, true)
        let loaded = try handlers.imageLoader.load(relativePath: r.screenshotPath!, paths: temp.paths)
        XCTAssertEqual(loaded.mimeType, "image/jpeg")
        XCTAssertTrue(loaded.resized, "HEIC はそのまま渡さず変換する")
        let stored = try await temp.store.get(id: r.id)
        XCTAssertEqual(stored?.handoffs.map(\.to), ["claude-code"])
    }

    /// masked の HEIC はマスク版を JPEG にして返す。黒塗りの領域は JPEG にも残る（画素で確かめる）。
    func testHEICMaskedKeepsBlackedOutRegionInJPEG() async throws {
        let r = try await insertWithHEIC(Fixtures.record("HEIC の masked", guardStatus: .masked))
        let result = try await call("get_capture", ["id": .string(r.id), "include_image": true], client: "hermes")
        let image = try XCTUnwrap(result.images.first)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        let decoded = try decodeImage(image.data)
        let w = decoded.width, h = decoded.height
        for y in [h / 10, h / 2, h * 9 / 10] {
            // 左半分（黒塗り）は黒のまま、右半分（元の明るい灰色）は明るいまま
            XCTAssertLessThan(HEICFixtures.brightness(of: decoded, x: w / 4, y: y), 20, "黒塗りが残っている (y=\(y))")
            XCTAssertLessThan(HEICFixtures.brightness(of: decoded, x: w / 20, y: y), 20)
            XCTAssertLessThan(HEICFixtures.brightness(of: decoded, x: w / 2 - 4, y: y), 30)
            XCTAssertGreaterThan(HEICFixtures.brightness(of: decoded, x: w * 3 / 4, y: y), 200, "マスクしていない側は元の色")
        }
        let loaded = try handlers.imageLoader.load(relativePath: r.maskedScreenshotPath!, paths: temp.paths)
        XCTAssertTrue(loaded.resized)
        // 元画像（黒塗りなし）ではないこと
        let original = try handlers.imageLoader.load(relativePath: r.screenshotPath!, paths: temp.paths)
        XCTAssertNotEqual(original.data, Data(base64Encoded: image.data))
    }

    /// 長辺が `maxSourcePixelSize` を超える HEIC は `maxPixelSize` まで縮小した JPEG になる（PNG でも同じ）。
    func testHEICAndPNGAboveMaxSourcePixelSizeAreDownscaled() async throws {
        handlers = MCPToolHandlers(store: temp.store, imageLoader: MCPImageLoader(maxPixelSize: 512, maxSourcePixelSize: 1000))
        let heic = try await insertWithHEIC(Fixtures.record("大きい HEIC", guardStatus: .masked), width: 1600, height: 900)
        var result = try await call("get_capture", ["id": .string(heic.id), "include_image": true])
        var image = try XCTUnwrap(result.images.first)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        var decoded = try decodeImage(image.data)
        XCTAssertEqual(max(decoded.width, decoded.height), 512, "長辺を maxPixelSize に")
        XCTAssertEqual(Double(decoded.width) / Double(decoded.height), 1600.0 / 900.0, accuracy: 0.02, "縦横比は保つ")
        XCTAssertLessThan(HEICFixtures.brightness(of: decoded, x: decoded.width / 4, y: decoded.height / 2), 20, "縮小しても黒塗りは残る")

        // 小さいファイル（maxBytes 以下）の PNG でも、長辺が maxSourcePixelSize を超えれば縮小する
        var png = Fixtures.record("大きい PNG", guardStatus: .clear)
        png.screenshotPath = try await temp.store.writeAttachment(Fixtures.imageData(width: 1200, height: 400, type: .png),
                                                                  id: png.id, kind: .screenshot, ext: "png", capturedAt: png.capturedAt)
        try await temp.store.insert(png)
        result = try await call("get_capture", ["id": .string(png.id), "include_image": true])
        image = try XCTUnwrap(result.images.first)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        decoded = try decodeImage(image.data)
        XCTAssertEqual(decoded.width, 512)

        // 超えない PNG はそのまま
        var small = Fixtures.record("小さい PNG", guardStatus: .clear)
        small.screenshotPath = try await temp.store.writeAttachment(Fixtures.imageData(width: 900, height: 300, type: .png),
                                                                    id: small.id, kind: .screenshot, ext: "png", capturedAt: small.capturedAt)
        try await temp.store.insert(small)
        result = try await call("get_capture", ["id": .string(small.id), "include_image": true])
        XCTAssertEqual(result.images.first?.mimeType, "image/png")
    }

    /// 保持期間でスクショを消した記録は「スクショがありません」（needs_review の確認待ちのままにしない）。
    func testPurgedScreenshotIsReportedAsNoScreenshot() async throws {
        let r = try await insertWithHEIC(Fixtures.record("消える要確認", guardStatus: .needsReview))
        if case .deny(let reason) = MCPToolHandlers.imageDecision(r) {
            XCTAssertTrue(reason.contains("確認待ち"), reason)
        } else { XCTFail("needs_review は渡さない") }
        let purged = try await temp.store.purgeExpiredScreenshots(retentionDays: 1, now: r.capturedAt.addingTimeInterval(3 * 86400))
        XCTAssertEqual(purged, 1)
        let fetched = try await temp.store.get(id: r.id)
        let after = try XCTUnwrap(fetched)
        XCTAssertEqual(MCPToolHandlers.imageDecision(after), .deny(reason: "この記録にはスクショがありません"))
        let result = try await call("get_capture", ["id": .string(r.id), "include_image": true])
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(try result.json()["image_omitted_reason"] as? String, "この記録にはスクショがありません")
        XCTAssertEqual(try result.json()["guard_status"] as? String, "clear")
    }

    func testGetCaptureNotFoundAndValidation() async throws {
        let missing = ULID.generate().string
        let result = try await call("get_capture", ["id": .string(missing)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(result.texts.first?.contains("見つかりません") == true)

        await assertInvalidParams(try await call("get_capture"), "id")
        await assertInvalidParams(try await call("get_capture", ["id": "not-a-ulid"]), "ULID")
        await assertInvalidParams(try await call("get_capture", ["id": "8ZZZZZZZZZZZZZZZZZZZZZZZZZ"]), "ULID")  // 先頭 8 は範囲外
        await assertInvalidParams(try await call("get_capture", ["id": "01HZZZZZZZZZZZZZZZZZZZZZZI"]), "ULID")  // I は使わない
        await assertInvalidParams(try await call("get_capture", ["id": 1]), "id")
        await assertInvalidParams(try await call("get_capture", ["id": .string(missing), "include_image": "true"]), "include_image")
    }

    func testLowercaseIDIsAccepted() async throws {
        let r = Fixtures.record("小文字の id")
        try await temp.store.insert(r)
        let result = try await call("get_capture", ["id": .string(r.id.lowercased())])
        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(try result.json()["id"] as? String, r.id)
    }

    // MARK: - add_note / mark_done / archive

    func testAddNoteUsesClientNameAsAuthor() async throws {
        let r = Fixtures.record("調べて")
        try await temp.store.insert(r)
        let json = try await call("add_note", ["id": .string(r.id), "text": "  原因は lookup()  "]).json()
        XCTAssertEqual(json["notes_count"] as? Int, 1)
        XCTAssertEqual((json["note"] as? [String: Any])?["author"] as? String, "claude-code")

        _ = try await call("add_note", ["id": .string(r.id), "text": "2 件目"], client: nil)
        _ = try await call("add_note", ["id": .string(r.id), "text": "3 件目"], client: " evil\nname\u{0007} ")
        let stored = try await temp.store.get(id: r.id)
        XCTAssertEqual(stored?.notes.map(\.author), ["claude-code", "mcp-client", "evilname"])
        XCTAssertEqual(stored?.notes.first?.text, "原因は lookup()")
        XCTAssertEqual(stored?.notes.first?.at, fixedNow)
    }

    func testAddNoteValidationAndNotFound() async throws {
        let r = Fixtures.record("x")
        try await temp.store.insert(r)
        await assertInvalidParams(try await call("add_note", ["id": .string(r.id)]), "text")
        await assertInvalidParams(try await call("add_note", ["id": .string(r.id), "text": " \n "]), "text")
        await assertInvalidParams(try await call("add_note", ["id": .string(r.id), "text": .string(String(repeating: "a", count: 4001))]), "4000")
        await assertInvalidParams(try await call("add_note", ["text": "x"]), "id")
        let ok = try await call("add_note", ["id": .string(r.id), "text": .string(String(repeating: "a", count: 4000))])
        XCTAssertEqual(ok.isError, false)

        let result = try await call("add_note", ["id": .string(ULID.generate().string), "text": "x"])
        XCTAssertEqual(result.isError, true)
    }

    func testMarkDoneAndArchive() async throws {
        let r = Fixtures.record("片付け")
        try await temp.store.insert(r)

        var json = try await call("mark_done", ["id": .string(r.id)]).json()
        XCTAssertEqual(json["status"] as? String, "done")
        XCTAssertEqual(json["previous_status"] as? String, "inbox")
        var listed = try await call("list_inbox").json()
        XCTAssertEqual(listed["count"] as? Int, 0, "done は Inbox から消える")

        json = try await call("archive", ["id": .string(r.id)]).json()
        XCTAssertEqual(json["status"] as? String, "archived")
        XCTAssertEqual(json["previous_status"] as? String, "done")
        let stored = try await temp.store.get(id: r.id)
        XCTAssertEqual(stored?.status, .archived, "アーカイブは削除ではない")
        listed = try await call("list_inbox").json()
        XCTAssertEqual(listed["count"] as? Int, 0)

        for tool in ["mark_done", "archive"] {
            let nf = try await call(tool, ["id": .string(ULID.generate().string)])
            XCTAssertEqual(nf.isError, true)
            await assertInvalidParams(try await call(tool, ["id": "x"]), "ULID")
            await assertInvalidParams(try await call(tool, ["id": .string(r.id), "force": true]), "未知の引数")
        }
    }
}
