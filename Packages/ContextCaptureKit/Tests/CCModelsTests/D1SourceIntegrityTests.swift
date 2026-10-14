import CCCore
import CryptoKit
import Foundation
import XCTest
@testable import CCModels

final class D1SourceIntegrityTests: XCTestCase {
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testPinsCoverEverySourceIncludingTokenizerAndConfig() {
        XCTAssertEqual(Set(D1ModelPreparer.sourceSHA256.keys), Set(D1ModelPreparer.sourceFiles))
        XCTAssertTrue(D1ModelPreparer.sourceSHA256.values.allSatisfy { $0.count == 64 })
    }

    func testModifiedSourceMetadataIsRejectedBeforeConversionOrReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("d1-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let keep = destination.appendingPathComponent("keep.txt")
        try Data("existing model".utf8).write(to: keep)
        var preparer = D1ModelPreparer(destination: destination)
        var valid: [String: Data] = [:]
        for name in D1ModelPreparer.sourceFiles {
            let data = Data(name.utf8)
            valid[name] = data
            try data.write(to: source.appendingPathComponent(name))
            preparer.sourceChecksums[name] = sha(data)
        }
        XCTAssertEqual(try preparer.verifySource(directory: source), preparer.sourceChecksums)
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "LICENSE"] {
            try Data(repeating: 120, count: valid[name]!.count).write(to: source.appendingPathComponent(name))
            XCTAssertThrowsError(try preparer.convert(source: source)) { error in
                guard case let D1PrepareError.sourceFileChecksumMismatch(path, _, _) = error else {
                    return XCTFail("unexpected: \(error)")
                }
                XCTAssertEqual(path, name)
            }
            XCTAssertEqual(try Data(contentsOf: keep), Data("existing model".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["model", "source"])
            try valid[name]!.write(to: source.appendingPathComponent(name))
        }
        try FileManager.default.removeItem(at: source.appendingPathComponent("chat_template.jinja"))
        XCTAssertThrowsError(try preparer.verifySource(directory: source))
    }

    func testPinnedCacheSourceHashes() throws {
        guard ProcessInfo.processInfo.environment["CC_RUN_SOURCE_VERIFY"] == "1" else { throw XCTSkip("opt-in fixed source verification") }
        let source = try XCTUnwrap(D1ModelPreparer.pythonHFCacheSnapshot())
        let preparer = D1ModelPreparer(destination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(try preparer.verifySource(directory: source), D1ModelPreparer.sourceSHA256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparer.destination.path))
    }
}
