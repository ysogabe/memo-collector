import CCCore
import Foundation
import XCTest

final class SearchIndexStateTests: XCTestCase {
    /// Wave 5 のアプリ（`app/.../SearchIndex.swift` の旧定義）が書いた形式をそのまま読めること。
    func testReadsExistingWave5File() throws {
        let json = """
        {
          "dimension" : 256,
          "image_tokens" : 280,
          "index_signature" : "embeddinggemma-2-coreml@3f978dd/img280/d256",
          "status" : "ready",
          "updated_at" : "2026-10-10T12:34:56Z"
        }
        """
        let s = try SearchIndexState.decode(Data(json.utf8))
        XCTAssertEqual(s.indexSignature, "embeddinggemma-2-coreml@3f978dd/img280/d256")
        XCTAssertEqual(s.imageTokens, 280)
        XCTAssertEqual(s.dimension, 256)
        XCTAssertEqual(s.status, .ready)
        XCTAssertEqual(s.updatedAt, ISO8601DateFormatter().date(from: "2026-10-10T12:34:56Z"))
        XCTAssertNil(s.failedIDs)

        let rebuilding = try SearchIndexState.decode(Data(json.replacingOccurrences(of: "\"ready\"", with: "\"rebuilding\"").utf8))
        XCTAssertEqual(rebuilding.status, .rebuilding)
    }

    func testRoundTripAndKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sis-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = CCPaths(dataRoot: dir.appendingPathComponent("data"), modelsRoot: dir.appendingPathComponent("models"))
        XCTAssertEqual(paths.searchIndexStateURL.lastPathComponent, "search-index.json")
        XCTAssertNil(SearchIndexState.read(paths: paths))

        let state = SearchIndexState(indexSignature: "sig", imageTokens: 140, dimension: 256, status: .degraded,
                                     updatedAt: Date(timeIntervalSince1970: 1_791_500_000), failedIDs: ["A", "B"])
        try state.write(to: paths.searchIndexStateURL)  // 親ディレクトリが無くても作る
        XCTAssertEqual(SearchIndexState.read(paths: paths), state)

        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.searchIndexStateURL)) as? [String: Any])
        XCTAssertEqual(Set(raw.keys), ["index_signature", "image_tokens", "dimension", "status", "updated_at", "failed_ids"])
        XCTAssertEqual(raw["status"] as? String, "degraded")

        // failed_ids が無ければ書かない（旧形式と同じキー）。
        var ready = state
        ready.status = .ready
        ready.failedIDs = nil
        let readyRaw = try XCTUnwrap(JSONSerialization.jsonObject(with: ready.encoded()) as? [String: Any])
        XCTAssertNil(readyRaw["failed_ids"])
    }

    /// 知らない状態の値も読める（ready ではないので cc-mcp はベクトル検索を使わない）。壊れたファイルは nil。
    func testUnknownStatusAndBrokenFile() throws {
        let json = #"{"dimension":256,"image_tokens":70,"index_signature":"s","status":"future","updated_at":"2026-10-10T00:00:00Z"}"#
        let s = try SearchIndexState.decode(Data(json.utf8))
        XCTAssertEqual(s.status.rawValue, "future")
        XCTAssertNotEqual(s.status, .ready)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sis-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = SearchIndexState.url(dataRoot: dir)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertNil(SearchIndexState.read(from: url))
    }
}
