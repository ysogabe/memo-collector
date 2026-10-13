import CCCore
import CCStore
import Foundation
import MCP
import XCTest
@testable import CCMCP

/// SDK の Server 越し（インメモリのトランスポート）で、initialize の clientInfo.name が author / handoff に入ることを確かめる。
final class ContextCaptureMCPServerTests: XCTestCase {
    func testInMemoryRoundTripUsesClientInfoName() async throws {
        let temp = try TempStore()
        let r = Fixtures.record("サーバー越し")
        try await temp.store.insert(r)

        let server = ContextCaptureMCPServer(handlers: MCPToolHandlers(store: temp.store))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)

        let client = Client(name: "test-agent", version: "1.0")
        let initResult = try await client.connect(transport: clientTransport)
        XCTAssertEqual(initResult.serverInfo.name, "context-capture")
        XCTAssertTrue(initResult.instructions?.contains("needs_review") == true)
        XCTAssertNotNil(initResult.capabilities.tools)
        let name = await server.clientName
        XCTAssertEqual(name, "test-agent")

        let tools = try await client.listTools().tools
        XCTAssertEqual(tools.map(\.name), CCMCPToolName.allCases.map(\.rawValue))

        let added = try await client.callTool(name: "add_note", arguments: ["id": .string(r.id), "text": "PR を出した"])
        XCTAssertEqual(added.isError, false)
        let stored = try await temp.store.get(id: r.id)
        XCTAssertEqual(stored?.notes.first?.author, "test-agent")

        // 入力エラーは JSON-RPC のエラー（-32602）で返る。
        do {
            _ = try await client.callTool(name: "list_inbox", arguments: ["limit": 999])
            XCTFail("エラーにならなかった")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, -32602)
        }
        do {
            _ = try await client.callTool(name: "delete", arguments: ["id": .string(r.id)])
            XCTFail("エラーにならなかった")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, -32602)
        }

        await client.disconnect()
        await server.stop()
    }
}

/// `cc-mcp` の実行ファイルを起動し、stdio で JSON-RPC を往復する結合テスト。
final class CCMCPStdioIntegrationTests: XCTestCase {
    /// `.build/<config>/cc-mcp`（xctest バンドルと同じディレクトリ）。
    func executableURL() throws -> URL {
        let dir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent("cc-mcp")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            XCTFail("cc-mcp の実行ファイルが無い: \(url.path)。先に `swift build` を実行すること")
            throw XCTSkip("cc-mcp が無い")
        }
        return url
    }

    func testStdioInitializeListToolsAndListInbox() async throws {
        let exe = try executableURL()
        let temp = try TempStore()
        let base = Date(timeIntervalSince1970: 1_791_500_000)
        let older = Fixtures.record("古い code の件", at: base)
        let newer = Fixtures.record("新しい code の件", at: base.addingTimeInterval(60), guardStatus: .needsReview)
        try await temp.store.insert(older)
        try await temp.store.insert(newer)

        let proc = try StdioProcess(executable: exe, environment: [CCPaths.dataDirEnvironmentKey: temp.paths.dataRoot.path])
        defer { proc.terminate() }

        // initialize
        try proc.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "stdio-test", "version": "0.0.1"],
            ],
        ])
        let initResponse = try proc.receive(id: 1)
        let initResult = try XCTUnwrap(initResponse["result"] as? [String: Any], "\(initResponse)")
        XCTAssertEqual((initResult["serverInfo"] as? [String: Any])?["name"] as? String, "context-capture")
        XCTAssertEqual(initResult["protocolVersion"] as? String, "2025-06-18")
        XCTAssertTrue((initResult["instructions"] as? String)?.contains("needs_review") == true)
        try proc.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        // tools/list
        try proc.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let listResponse = try proc.receive(id: 2)
        let tools = try XCTUnwrap((listResponse["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["list_inbox", "search_captures", "get_capture", "add_note", "mark_done", "archive"])
        let listSchema = try XCTUnwrap(tools.first?["inputSchema"] as? [String: Any])
        XCTAssertEqual(((listSchema["properties"] as? [String: Any])?["limit"] as? [String: Any])?["maximum"] as? Int, 50)

        // tools/call list_inbox
        try proc.send([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "list_inbox", "arguments": ["intent": "code", "limit": 10]],
        ])
        let callResponse = try proc.receive(id: 3)
        let callResult = try XCTUnwrap(callResponse["result"] as? [String: Any], "\(callResponse)")
        XCTAssertEqual(callResult["isError"] as? Bool, false)
        let content = try XCTUnwrap(callResult["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((content.first?["text"] as? String ?? "").utf8)) as? [String: Any])
        let items = try XCTUnwrap(payload["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, [newer.id, older.id])
        XCTAssertEqual(items.first?["guard_status"] as? String, "needs_review")

        // 入力エラーは JSON-RPC のエラー。
        try proc.send([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "get_capture", "arguments": ["id": "../../etc/passwd"]],
        ])
        let errorResponse = try proc.receive(id: 4)
        XCTAssertEqual((errorResponse["error"] as? [String: Any])?["code"] as? Int, -32602)

        // add_note の author は initialize の clientInfo.name。
        try proc.send([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "add_note", "arguments": ["id": older.id, "text": "stdio から追記"]],
        ])
        _ = try proc.receive(id: 5)
        let stored = try await temp.store.get(id: older.id)
        XCTAssertEqual(stored?.notes.map(\.author), ["stdio-test"])

        // 標準入力を閉じると終了する。標準出力には JSON-RPC 以外を出していない。
        proc.closeInput()
        XCTAssertTrue(proc.waitForExit(timeout: 10), "stdin を閉じても終了しない")
        XCTAssertTrue(proc.nonJSONLines.isEmpty, "標準出力に JSON 以外: \(proc.nonJSONLines)")
        XCTAssertFalse(proc.stderrText.contains("古い code の件"), "注釈本文をログに出さない")
    }

    /// まとめて書いてすぐ stdin を閉じても、受信済みのツール呼び出しには全部応答してから終わる。
    func testPipedRequestsAreAllAnsweredBeforeExit() async throws {
        let exe = try executableURL()
        let temp = try TempStore()
        try await temp.store.insert(Fixtures.record("パイプの件"))
        let proc = try StdioProcess(executable: exe, environment: [CCPaths.dataDirEnvironmentKey: temp.paths.dataRoot.path])
        defer { proc.terminate() }
        try proc.send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                  "clientInfo": ["name": "pipe", "version": "0"]]])
        try proc.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        for id in 2...6 {
            try proc.send(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                           "params": ["name": "search_captures", "arguments": ["query": "パイプ"]]])
        }
        proc.closeInput()
        XCTAssertTrue(proc.waitForExit(timeout: 15))
        let ids = Set(proc.stdoutLines.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? Int
        })
        XCTAssertEqual(ids, Set(1...6))
    }

    func testMissingDatabaseExitsWithError() throws {
        let exe = try executableURL()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccmcp-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let proc = try StdioProcess(executable: exe, environment: [CCPaths.dataDirEnvironmentKey: dir.path])
        XCTAssertTrue(proc.waitForExit(timeout: 10))
        XCTAssertNotEqual(proc.process.terminationStatus, 0)
        XCTAssertTrue(proc.stderrText.contains("データベースが見つからない"), proc.stderrText)
        XCTAssertTrue(proc.stdoutLines.isEmpty, "標準出力には何も出さない")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(CCPaths.databaseFileName).path),
                       "DB を勝手に作らない")
    }
}

/// 子プロセスを起動し、標準出力を行単位（改行区切りの JSON-RPC）で読む。
final class StdioProcess: @unchecked Sendable {
    let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var errData = Data()
    private let lineSignal = DispatchSemaphore(value: 0)

    init(executable: URL, environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = []
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            self.lock.lock(); self.errData.append(data); self.lock.unlock()
        }
        try process.run()
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var newLines = 0
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer = Data(buffer[(nl + 1)...])
            if !line.isEmpty { lines.append(line); newLines += 1 }
        }
        lock.unlock()
        for _ in 0..<newLines { lineSignal.signal() }
    }

    var stdoutLines: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    var stderrText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errData, as: UTF8.self) }
    var nonJSONLines: [String] {
        stdoutLines.filter { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) == nil }
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(UInt8(ascii: "\n"))
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    /// 指定 id の応答を待つ（通知など他の行は読み飛ばす）。
    func receive(id: Int, timeout: TimeInterval = 30) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var scanned = 0
        while true {
            let current = stdoutLines
            while scanned < current.count {
                let line = current[scanned]
                scanned += 1
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   obj["id"] as? Int == id {
                    return obj
                }
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 || lineSignal.wait(timeout: .now() + remaining) == .timedOut {
                throw NSError(domain: "StdioProcess", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "id=\(id) の応答が \(timeout) 秒以内に来ない。stderr: \(stderrText)",
                ])
            }
        }
    }

    func closeInput() {
        try? stdin.fileHandleForWriting.close()
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if !process.isRunning {
            // 残りの出力を読み切る。
            stdout.fileHandleForReading.readabilityHandler = nil
            append(stdout.fileHandleForReading.readDataToEndOfFile())
            stderr.fileHandleForReading.readabilityHandler = nil
            let rest = stderr.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData.append(rest); lock.unlock()
        }
        return !process.isRunning
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
