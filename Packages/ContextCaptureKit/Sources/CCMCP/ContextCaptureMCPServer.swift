import CCCore
import Foundation
import MCP

/// MCP サーバーの組み立て。SDK の `Server` に 6 ツールを登録し、initialize の clientInfo.name を覚える
/// （`add_note` の author と handoff の to に使う。SDK は clientInfo を公開しないので initializeHook で受け取る）。
public final class ContextCaptureMCPServer: Sendable {
    public static let serverName = "context-capture"
    public static let serverVersion = "0.1.0"

    public let server: Server
    public let handlers: MCPToolHandlers
    private let client = ClientNameBox()
    private let inFlight = InFlightCounter()

    public init(handlers: MCPToolHandlers) {
        self.handlers = handlers
        self.server = Server(
            name: Self.serverName,
            version: Self.serverVersion,
            title: "Context Capture",
            instructions: CCMCPToolCatalog.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    /// 接続したクライアントの名前（initialize 前は nil）。
    public var clientName: String? {
        get async { await client.name }
    }

    /// ハンドラを登録してトランスポートで待ち受けを始める（すぐ戻る。終了待ちは `waitUntilCompleted`）。
    public func start(transport: any Transport) async throws {
        let handlers = self.handlers
        let client = self.client
        let inFlight = self.inFlight
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: CCMCPToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            let started = Date()
            await inFlight.begin()
            defer { Task { await inFlight.end() } }
            do {
                let result = try await handlers.call(name: params.name, arguments: params.arguments, clientName: await client.name)
                MCPLog.write("\(params.name): \(result.isError == true ? "error" : "ok")（\(Self.elapsed(since: started))）")
                return result
            } catch {
                MCPLog.write("\(params.name): 入力エラー（\(Self.elapsed(since: started))）")
                throw error
            }
        }
        try await server.start(transport: transport) { info, _ in
            await client.set(info.name)
        }
    }

    /// クライアントが切断する（stdin が閉じる）まで待ち、処理中のツール呼び出しが応答を返し終わるのも待つ
    /// （SDK は EOF で受信ループを抜けるが、受信済みのリクエストは別タスクで処理中のことがある）。
    public func waitUntilCompleted(drainTimeout: TimeInterval = 30) async {
        await server.waitUntilCompleted()
        // 受信済みでハンドラに入る直前のリクエストを拾うための短い猶予。
        try? await Task.sleep(for: .milliseconds(200))
        let deadline = Date().addingTimeInterval(drainTimeout)
        while await inFlight.count > 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // 応答の送信（ハンドラが返った後）を待つ。
        try? await Task.sleep(for: .milliseconds(100))
    }

    public func stop() async {
        await server.stop()
    }

    private static func elapsed(since start: Date) -> String {
        String(format: "%.0fms", Date().timeIntervalSince(start) * 1000)
    }
}

private actor InFlightCounter {
    private(set) var count = 0
    func begin() { count += 1 }
    func end() { count -= 1 }
}

private actor ClientNameBox {
    var name: String?
    func set(_ name: String) { self.name = name }
}
