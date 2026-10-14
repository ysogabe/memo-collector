import CCCore
import CCModels
import CCSTT
import Foundation
import XCTest

final class ModelSlotIntegrityTests: XCTestCase {
    func testD1CorruptManifestDoesNotBecomeMultiGigabyteDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slot-integrity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("d1")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in D1ModelPreparer.requiredFiles { try Data("x".utf8).write(to: dest.appendingPathComponent(name)) }
        try Data("invalid JSON".utf8).write(to: dest.appendingPathComponent("manifest.json"))
        let slot = D1ModelSlot(preparer: D1ModelPreparer(destination: dest))
        do { try await slot.prepare { _, _ in }; XCTFail("malformed manifest must be reported") }
        catch is DecodingError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".downloads").path))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("model.safetensors")), Data("x".utf8))
    }

    func testD1AndEmbeddingUnmanifestedDevelopmentFilesAreReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slot-development-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let d1 = root.appendingPathComponent("d1"), embedding = root.appendingPathComponent("embedding")
        for (dir, names) in [(d1, D1ModelPreparer.requiredFiles), (embedding, EmbeddingModelPreparer.requiredFiles)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in names {
                if name.hasSuffix(".mlmodelc") { try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true) }
                else { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
            }
        }
        // Explicit developer model roots stay read-only. Model preparer's adoption path is tested separately.
        try await D1ModelSlot(preparer: D1ModelPreparer(destination: d1)).prepare { _, _ in }
        try await EmbeddingModelSlot(preparer: EmbeddingModelPreparer(destination: embedding)).prepare { _, _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: d1.appendingPathComponent("manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: embedding.appendingPathComponent("manifest.json").path))
    }
}
