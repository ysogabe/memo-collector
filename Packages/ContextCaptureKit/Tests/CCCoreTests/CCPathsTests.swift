import XCTest
@testable import CCCore

final class CCPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    func testDefaults() {
        let p = CCPaths.resolve(environment: [:], homeDirectory: home)
        XCTAssertEqual(p.dataRoot.path, "/Users/tester/Library/Application Support/ContextCapture")
        XCTAssertEqual(p.modelsRoot.path, "/Users/tester/Library/Application Support/ContextCapture/Models")
        XCTAssertEqual(p.databaseURL.path, "/Users/tester/Library/Application Support/ContextCapture/ContextCapture.sqlite")
        XCTAssertEqual(p.capturesRoot.lastPathComponent, "captures")
        XCTAssertEqual(p.modelDirectory(.d1).lastPathComponent, "d1-3b-text-q8")
        XCTAssertEqual(p.modelDirectory(.embedding).lastPathComponent, "embeddinggemma-2")
        XCTAssertEqual(p.modelDirectory(.whisper).lastPathComponent, "whisperkit")
        XCTAssertEqual(p.manifestURL(.d1).path, "/Users/tester/Library/Application Support/ContextCapture/Models/d1-3b-text-q8/manifest.json")
    }

    func testEnvironmentOverrides() {
        let p = CCPaths.resolve(environment: ["CC_DATA_DIR": "/tmp/cc-data", "CC_MODELS_DIR": "/tmp/cc-models/"], homeDirectory: home)
        XCTAssertEqual(p.dataRoot.path, "/tmp/cc-data")
        XCTAssertEqual(p.modelsRoot.path, "/tmp/cc-models")
    }

    func testDataOverrideDoesNotMoveModels() {
        let p = CCPaths.resolve(environment: ["CC_DATA_DIR": "/tmp/cc-data"], homeDirectory: home)
        XCTAssertEqual(p.modelsRoot.path, "/Users/tester/Library/Application Support/ContextCapture/Models")
    }

    func testEmptyEnvironmentValueIsIgnored() {
        let p = CCPaths.resolve(environment: ["CC_DATA_DIR": "", "CC_MODELS_DIR": ""], homeDirectory: home)
        XCTAssertEqual(p, CCPaths.resolve(environment: [:], homeDirectory: home))
    }

    func testTildeIsExpanded() {
        let p = CCPaths.resolve(environment: ["CC_MODELS_DIR": "~/models"], homeDirectory: home)
        XCTAssertEqual(p.modelsRoot.path, (NSString(string: "~/models").expandingTildeInPath))
    }

    func testAttachmentRelativePathUsesLocalDate() throws {
        let at = try XCTUnwrap(CCJSON.parseDate("2026-10-08T23:15:32+09:00"))  // UTC では 10/08 14:15
        let jst = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(
            CCPaths.attachmentRelativePath(id: "01JA9Z3K8Q4V7X2M5N6P8R0T1W", kind: .screenshot, ext: "webp", capturedAt: at, timeZone: jst),
            "captures/2026/10/08/01JA9Z3K8Q4V7X2M5N6P8R0T1W.webp")
        XCTAssertEqual(
            CCPaths.attachmentRelativePath(id: "X", kind: .maskedScreenshot, ext: ".webp", capturedAt: at, timeZone: jst),
            "captures/2026/10/08/X-masked.webp")
        XCTAssertEqual(
            CCPaths.attachmentRelativePath(id: "X", kind: .audio, ext: "m4a", capturedAt: at, timeZone: jst),
            "captures/2026/10/08/X.m4a")
        // 日付はタイムゾーンで変わる（JST 2026-10-09 01:00 は UTC では 10/08）
        let late = try XCTUnwrap(CCJSON.parseDate("2026-10-09T01:00:00+09:00"))
        XCTAssertEqual(CCPaths.attachmentRelativePath(id: "X", kind: .audio, ext: "m4a", capturedAt: late, timeZone: jst), "captures/2026/10/09/X.m4a")
        XCTAssertEqual(CCPaths.attachmentRelativePath(id: "X", kind: .audio, ext: "m4a", capturedAt: late, timeZone: TimeZone(identifier: "UTC")!), "captures/2026/10/08/X.m4a")
        // 1 桁の月日はゼロ埋め
        let jan = try XCTUnwrap(CCJSON.parseDate("2027-01-02T12:00:00+09:00"))
        XCTAssertEqual(CCPaths.attachmentRelativePath(id: "X", kind: .screenshot, ext: "webp", capturedAt: jan, timeZone: jst), "captures/2027/01/02/X.webp")
    }

    func testURLForRelativePath() throws {
        let p = CCPaths(dataRoot: URL(fileURLWithPath: "/tmp/cc", isDirectory: true), modelsRoot: URL(fileURLWithPath: "/tmp/m"))
        XCTAssertEqual(try p.url(forRelativePath: "captures/2026/10/08/X.webp").path, "/tmp/cc/captures/2026/10/08/X.webp")
        for bad in ["", "/etc/passwd", "~/x", "../x", "captures/../../x", "captures//x", "./x"] {
            XCTAssertThrowsError(try p.url(forRelativePath: bad), bad)
        }
    }

    func testCreateDirectories() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cc-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = CCPaths.resolve(environment: ["CC_DATA_DIR": tmp.appendingPathComponent("data").path,
                                              "CC_MODELS_DIR": tmp.appendingPathComponent("models").path])
        try p.createDirectories()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.capturesRoot.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.modelsRoot.path))
    }
}
