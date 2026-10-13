import CCCore
import Foundation
import XCTest

final class Wave5CoreTests: XCTestCase {
    func testRoundedToMilliseconds() {
        // Date は 2001 年基準の Double なので、比較はミリ秒単位の整数で行う。
        func millis(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }
        let base: TimeInterval = 1_791_468_000
        let down = Date(timeIntervalSince1970: base + 0.1234).roundedToMilliseconds
        let up = Date(timeIntervalSince1970: base + 0.1236).roundedToMilliseconds
        XCTAssertEqual(millis(down), (base + 0.123) * 1000)
        XCTAssertEqual(millis(up), (base + 0.124) * 1000)
        XCTAssertEqual(down.timeIntervalSince1970 * 1000, millis(down), accuracy: 1e-3)
        XCTAssertEqual(down.roundedToMilliseconds, down)
    }

    func testRoundedDateSurvivesCCJSON() throws {
        struct Box: Codable, Equatable { var at: Date }
        let box = Box(at: Date(timeIntervalSince1970: 1_791_468_000.123456).roundedToMilliseconds)
        let back = try CCJSON.decoder().decode(Box.self, from: CCJSON.encoder().encode(box))
        XCTAssertEqual(back, box)
    }

    // MARK: - CCPaths.resolveRegularFileInsideDataRoot

    private func makeRoot() throws -> (CCPaths, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CCCoreTests-\(UUID().uuidString)")
        let root = base.appendingPathComponent("data", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("captures"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (CCPaths(dataRoot: root, modelsRoot: base.appendingPathComponent("models")), base, outside)
    }

    func testResolveInsideDataRoot() throws {
        let (paths, base, outside) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        try Data("ok".utf8).write(to: paths.dataRoot.appendingPathComponent("captures/a.heic"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        // データルート外を指すリンク、データルート内を指すリンク、ディレクトリ
        try fm.createSymbolicLink(at: paths.dataRoot.appendingPathComponent("captures/evil.heic"),
                                  withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: paths.dataRoot.appendingPathComponent("captures/alias.heic"),
                                  withDestinationURL: paths.dataRoot.appendingPathComponent("captures/a.heic"))

        let ok = try paths.resolveRegularFileInsideDataRoot("captures/a.heic")
        XCTAssertEqual(try Data(contentsOf: ok), Data("ok".utf8))
        let alias = try paths.resolveRegularFileInsideDataRoot("captures/alias.heic")
        XCTAssertEqual(alias.lastPathComponent, "a.heic")

        XCTAssertThrowsError(try paths.resolveRegularFileInsideDataRoot("captures/evil.heic")) {
            XCTAssertEqual($0 as? CCPathError, .outsideDataRoot("captures/evil.heic"))
        }
        XCTAssertThrowsError(try paths.resolveRegularFileInsideDataRoot("../outside/secret.txt")) {
            XCTAssertEqual($0 as? CCPathError, .outsideDataRoot("../outside/secret.txt"))
        }
        XCTAssertThrowsError(try paths.resolveRegularFileInsideDataRoot("/etc/hosts")) {
            XCTAssertEqual($0 as? CCPathError, .outsideDataRoot("/etc/hosts"))
        }
        XCTAssertThrowsError(try paths.resolveRegularFileInsideDataRoot("captures/missing.heic")) {
            XCTAssertEqual($0 as? CCPathError, .notRegularFile("captures/missing.heic"))
        }
        XCTAssertThrowsError(try paths.resolveRegularFileInsideDataRoot("captures")) {
            XCTAssertEqual($0 as? CCPathError, .notRegularFile("captures"))
        }
    }
}
