import CCCore
import CCStore
import Foundation
import MCP
import XCTest
@testable import CCMCP

/// 読み込み（温め）に時間のかかるフェイク埋め込み。`warm` の回数と作られた回数を数える。
final class WarmCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _made = 0
    private var _warmed = 0
    private var _failNext = false
    var made: Int { lock.withLock { _made } }
    var warmed: Int { lock.withLock { _warmed } }
    func didMake() { lock.withLock { _made += 1 } }
    func didWarm() { lock.withLock { _warmed += 1 } }
    func failNextWarm() { lock.withLock { _failNext = true } }
    func takeFail() -> Bool { lock.withLock { defer { _failNext = false }; return _failNext } }
}

final class WarmingQueryEmbedderTests: XCTestCase {
    var temp: TempStore!
    var counter: WarmCounter!

    override func setUpWithError() throws {
        temp = try TempStore()
        counter = WarmCounter()
    }

    override func tearDown() {
        temp = nil
    }

    private var stateURL: URL { temp.paths.searchIndexStateURL }

    private func writeState(_ status: SearchIndexState.Status, signature: String = "sig/a") throws {
        try SearchIndexState(indexSignature: signature, imageTokens: 280, dimension: 256, status: status, updatedAt: Date())
            .write(to: stateURL)
    }

    /// 状態ファイルのシグネチャをそのまま鍵にする。`reject` に入っているシグネチャは使わない。
    private func make(warmDelay: Duration, waitLimit: Duration = .milliseconds(150),
                      reject: Set<String> = []) -> WarmingQueryEmbedder {
        let counter = counter!
        return WarmingQueryEmbedder(stateURL: stateURL, waitLimit: waitLimit, log: { _ in }) { state in
            if reject.contains(state.indexSignature) { return .reject("rejected") }
            return .use(.init(
                key: state.indexSignature,
                make: { counter.didMake(); return FakeEmbedder() },
                warm: { _ in
                    try await Task.sleep(for: warmDelay)
                    if counter.takeFail() { throw NSError(domain: "warm", code: 1) }
                    counter.didWarm()
                }
            ))
        }
    }

    private func waitUntilWarm(_ e: WarmingQueryEmbedder, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await e.isWarm { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await e.isWarm
    }

    /// 起動直後の prewarm はすぐ戻り（stdio を待たせない）、温め中の検索は上限で部分一致（embedder_warming）、
    /// 温め終わればベクトル検索になる。
    func testPrewarmIsNonBlockingAndSearchFallsBackWhileWarming() async throws {
        try writeState(.ready)
        let r = Fixtures.record("alpha の件")
        try await temp.store.insert(r)
        try await temp.store.setEmbedding(id: r.id, vector: FakeEmbedder().vector(for: "alpha"))
        let e = make(warmDelay: .milliseconds(1500))

        let t0 = Date()
        let started = await e.prewarm()
        XCTAssertTrue(started)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5, "prewarm は読み込みを待たない")

        let handlers = MCPToolHandlers(store: temp.store, embedderResolver: { await e.resolve() })
        let t1 = Date()
        var json = try await handlers.call(name: "search_captures", arguments: ["query": "alpha"], clientName: nil).json()
        let waited = Date().timeIntervalSince(t1)
        XCTAssertEqual(json["mode"] as? String, "keyword")
        XCTAssertEqual(json["fallback_reason"] as? String, "embedder_warming")
        XCTAssertEqual(json["count"] as? Int, 1)
        XCTAssertGreaterThanOrEqual(waited, 0.12, "上限までは待つ")
        XCTAssertLessThan(waited, 1.2, "上限を過ぎたら読み込みを待たない")

        let warm = await waitUntilWarm(e)
        XCTAssertTrue(warm)
        json = try await handlers.call(name: "search_captures", arguments: ["query": "alpha"], clientName: nil).json()
        XCTAssertEqual(json["mode"] as? String, "vector")
        XCTAssertTrue(json["fallback_reason"] is NSNull)
        XCTAssertEqual(counter.made, 1)
        XCTAssertEqual(counter.warmed, 1)
    }

    /// 上限内に温め終われば、最初の検索からベクトル検索（待ってから使う）。
    func testWaitsWithinLimitThenUsesEmbedder() async throws {
        try writeState(.ready)
        let e = make(warmDelay: .milliseconds(50), waitLimit: .seconds(3))
        guard case .available = await e.resolve() else { return XCTFail("上限内に温め終わるので使える") }
        XCTAssertEqual(counter.warmed, 1)
    }

    /// アプリの作り直しで一時的に rebuilding / degraded になっても、同じシグネチャで ready に戻れば読み直さない。
    /// シグネチャが変わったときだけ作り直す。
    func testSameSignatureIsNotReloadedAfterRebuild() async throws {
        try writeState(.ready)
        let e = make(warmDelay: .milliseconds(10), waitLimit: .seconds(3))
        guard case .available = await e.resolve() else { return XCTFail() }

        try writeState(.rebuilding)
        guard case .unavailable = await e.resolve() else { return XCTFail("ready でなければ使わない") }
        try writeState(.degraded)
        guard case .unavailable = await e.resolve() else { return XCTFail("degraded でも cc-mcp は使わない") }
        try writeState(.ready)
        guard case .available = await e.resolve() else { return XCTFail() }
        XCTAssertEqual(counter.made, 1)
        XCTAssertEqual(counter.warmed, 1, "同じシグネチャは読み直さない")

        try writeState(.ready, signature: "sig/b")
        guard case .available = await e.resolve() else { return XCTFail() }
        XCTAssertEqual(counter.made, 2)
        XCTAssertEqual(counter.warmed, 2)
    }

    func testUnavailableCases() async throws {
        let e = make(warmDelay: .milliseconds(10), reject: ["sig/rejected"])
        let noFile = await e.prewarm()
        XCTAssertFalse(noFile, "状態ファイルが無ければ温めない")
        guard case .unavailable = await e.resolve() else { return XCTFail() }
        try writeState(.rebuilding)
        let rebuilding = await e.prewarm()
        XCTAssertFalse(rebuilding)
        try writeState(.ready, signature: "sig/rejected")
        guard case .unavailable = await e.resolve() else { return XCTFail("シグネチャ違い・モデル無し") }
        XCTAssertEqual(counter.made, 0)

        // 作り直しが終わって ready になったら、その検索で読み込みを始める。
        try writeState(.ready)
        let handlers = MCPToolHandlers(store: temp.store, embedderResolver: { await e.resolve() })
        let json = try await handlers.call(name: "search_captures", arguments: ["query": "x"], clientName: nil).json()
        XCTAssertEqual(json["mode"] as? String, "vector")
        XCTAssertEqual(counter.made, 1)
    }

    /// 読み込みに失敗したら embedder_failed、次の検索でやり直す。
    func testWarmFailureIsReportedAndRetried() async throws {
        try writeState(.ready)
        counter.failNextWarm()
        let e = make(warmDelay: .milliseconds(10), waitLimit: .seconds(3))
        let handlers = MCPToolHandlers(store: temp.store, embedderResolver: { await e.resolve() })
        var json = try await handlers.call(name: "search_captures", arguments: ["query": "x"], clientName: nil).json()
        XCTAssertEqual(json["fallback_reason"] as? String, "embedder_failed")
        json = try await handlers.call(name: "search_captures", arguments: ["query": "x"], clientName: nil).json()
        XCTAssertEqual(json["mode"] as? String, "vector")
        XCTAssertEqual(counter.made, 1)
        XCTAssertEqual(counter.warmed, 1)
    }
}
