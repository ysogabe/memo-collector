import CCCore
import CCStore
import CoreGraphics
import Foundation
import XCTest
@testable import CCTriage

final class IntentOnlyReprocessingTests: XCTestCase {
    private func setup() async throws -> (TempStore, ContextRecord, IntentOnlyRecordStore, FakeClassifier, TriageQueue, FakeScanner, FakeEmbedder, MaintenanceTestLoader) {
        let temp = try TempStore()
        var record = makeRecord()
        record.triage = TriageResult(probabilities: [.research: 0.7, .todo: 0.1, .code: 0.1, .note: 0.05, .schedule: 0.05], datetimeProbability: 0.2, model: "previous")
        try await temp.store.insert(record)
        let store = try IntentOnlyRecordStore(paths: CCPaths(dataRoot: temp.url, modelsRoot: temp.url.appendingPathComponent("Models")))
        let classifier = FakeClassifier(), scanner = FakeScanner(), embedder = FakeEmbedder(), loader = MaintenanceTestLoader()
        let queue = TriageQueue(store: store, classifier: classifier, scanner: scanner, embedder: embedder, screenshots: loader)
        return (temp, record, store, classifier, queue, scanner, embedder, loader)
    }

    func testIntentOnlyReprocessFailureKeepsExistingResultAndDoesNotReadAttachments() async throws {
        let (temp, record, _, classifier, queue, scanner, embedder, loader) = try await setup()
        await classifier.setFail(true)
        await queue.reprocess(id: record.id, steps: [.intent])
        await queue.waitUntilIdle()
        let saved = try await temp.store.get(id: record.id)
        XCTAssertEqual(saved, record)
        XCTAssertEqual(scanner.calls, 0)
        XCTAssertTrue(embedder.calls.isEmpty)
        XCTAssertEqual(loader.calls, 0)
    }

    func testSpecialTokenOnlyAnnotationIsExcludedByProductPreviewAndCannotClearExistingIntent() async throws {
        let (temp, record, store, classifier, queue, scanner, embedder, loader) = try await setup()
        try await temp.store.modify(id: record.id) { $0.annotation.text = " <|im_end|> \n<|startoftext|> " }
        let paths = CCPaths(dataRoot: temp.url, modelsRoot: temp.url.appendingPathComponent("Models"))
        let snapshot = try IntentMaintenance.preview(paths: paths, isAnnotationEmpty: { AnnotationPreprocessor.prepare($0).isEmpty })
        XCTAssertEqual(snapshot.emptyAnnotations, 1)
        XCTAssertEqual(snapshot.eligibleRecords, 0)
        // A stale caller may still submit the record. The queue skips empty prepared text,
        // and the restricted adapter refuses the queue's attempt to clear a previous result.
        await queue.reprocess(id: record.id, steps: [.intent])
        await queue.waitUntilIdle()
        let saved = try await temp.store.get(id: record.id)
        let calls = await classifier.texts
        XCTAssertEqual(saved?.triage, record.triage)
        XCTAssertEqual(store.changedResults, 0)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(scanner.calls, 0)
        XCTAssertTrue(embedder.calls.isEmpty)
        XCTAssertEqual(loader.calls, 0)
    }

    func testManualEditDuringIntentOnlyReprocessPreservesLabelAndOriginalProbabilities() async throws {
        let (temp, record, store, classifier, queue, _, _, _) = try await setup()
        await classifier.holdNextCall()
        let events = EventCollector(await queue.events())
        await queue.reprocess(id: record.id, steps: [.intent])
        await classifier.waitUntilHeld()
        try await temp.store.modify(id: record.id) { r in
            r.triage?.intent = .note
            r.triage?.model = TriageMarkers.manualModel
        }
        await classifier.release()
        await queue.waitUntilIdle()
        let saved = try await temp.store.get(id: record.id)
        XCTAssertEqual(saved?.triage?.intent, .note)
        XCTAssertEqual(saved?.triage?.intentProbabilities, record.triage?.intentProbabilities)
        XCTAssertEqual(store.changedResults, 0)
        _ = await events.wait { $0.contains(.idle) }
        XCTAssertTrue(events.events.contains(.stepFinished(id: record.id, step: .intent, outcome: .skipped(.manuallyEdited))))
        await queue.reprocess(id: record.id, steps: [.intent])
        await queue.waitUntilIdle()
        let calls = await classifier.texts
        XCTAssertEqual(calls.count, 1, "manual at processing start must not invoke the model")
    }

    func testAnnotationEditDuringIntentOnlyReprocessRejectsStaleResult() async throws {
        let (temp, record, store, classifier, queue, _, _, _) = try await setup()
        await classifier.holdNextCall()
        let events = EventCollector(await queue.events())
        await queue.reprocess(id: record.id, steps: [.intent])
        await classifier.waitUntilHeld()
        try await temp.store.modify(id: record.id) { $0.annotation.text = "更新した合成注釈" }
        await classifier.release()
        await queue.waitUntilIdle()
        let saved = try await temp.store.get(id: record.id)
        XCTAssertEqual(saved?.annotation.text, "更新した合成注釈")
        XCTAssertEqual(saved?.triage, record.triage)
        XCTAssertEqual(store.changedResults, 0)
        _ = await events.wait { $0.contains(.idle) }
        XCTAssertTrue(events.events.contains(.stepFinished(id: record.id, step: .intent, outcome: .skipped(.annotationChanged))))
    }

    func testDeletionDuringIntentOnlyReprocessDoesNotRecreateRecord() async throws {
        let (temp, record, store, classifier, queue, _, _, _) = try await setup()
        await classifier.holdNextCall()
        let events = EventCollector(await queue.events())
        await queue.reprocess(id: record.id, steps: [.intent])
        await classifier.waitUntilHeld()
        try await temp.store.delete(id: record.id)
        await classifier.release()
        await queue.waitUntilIdle()
        let saved = try await temp.store.get(id: record.id)
        XCTAssertNil(saved)
        XCTAssertEqual(store.changedResults, 0)
        _ = await events.wait { $0.contains(.idle) }
        XCTAssertTrue(events.events.contains(.stepFinished(id: record.id, step: .intent, outcome: .skipped(.recordMissing))))
    }
}

private final class MaintenanceTestLoader: ScreenshotLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func loadScreenshot(relativePath: String) async throws -> CGImage {
        lock.withLock { count += 1 }
        throw ScreenshotLoadError.notFound
    }
}
