import CCCore
import CCStore
import CoreGraphics
import Foundation
import XCTest
@testable import CCTriage

struct FakeError: Error {}

/// 一時データルートの本物の SQLiteRecordStore。
final class TempStore {
    let url: URL
    let store: SQLiteRecordStore

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("CCTriageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try SQLiteRecordStore(paths: CCPaths(dataRoot: url, modelsRoot: url.appendingPathComponent("Models")))
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func makeRecord(
    id: String = ULID.generate().string,
    offset: TimeInterval = 0,
    text: String = "明日までに見積もりに返信する",
    title: String? = "Slack",
    screenshot: String? = "captures/x/s.png"
) -> ContextRecord {
    ContextRecord(
        id: id,
        capturedAt: Date(timeIntervalSince1970: (1_791_468_000 + offset).rounded()),
        app: AppInfo(name: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
        window: WindowInfo(title: title, frame: nil),
        screenshotPath: screenshot,
        annotation: Annotation(text: text, sttEngine: "test")
    )
}

/// 分類器のフェイク。呼ばれたテキストを記録する。`gate` を設定すると classify がそこで止まる。
actor FakeClassifier: IntentClassifying, ModelUnloadable {
    var texts: [String] = []
    var fail = false
    var result = TriageResult(intent: .todo, intentConfidence: 0.9, mentionsDatetime: true, model: "fake-d1")
    var loaded = false
    var unloadCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    func setFail(_ v: Bool) { fail = v }
    func setResult(_ r: TriageResult) { result = r }
    /// 次の classify を `release()` まで止める。
    func holdNextCall() { holdNext = true }
    func release() { gate?.resume(); gate = nil }
    /// classify が止まるまで待つ。
    func waitUntilHeld() async {
        if gate != nil { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func classify(text: String) async throws -> TriageResult {
        texts.append(text)
        loaded = true
        if holdNext {
            holdNext = false
            await withCheckedContinuation { c in
                gate = c
                heldWaiters.forEach { $0.resume() }
                heldWaiters = []
            }
        }
        if fail { throw FakeError() }
        return result
    }

    func unload() async {
        if loaded { unloadCount += 1 }
        loaded = false
    }

    var isLoaded: Bool { loaded }
}

final class FakeScanner: SecretScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var findings: [SecretFinding] = []
    var fail = false
    var calls: Int { lock.withLock { _calls } }

    func scan(image: CGImage) async throws -> [SecretFinding] {
        lock.withLock { _calls += 1 }
        if fail { throw FakeError() }
        return findings
    }
}

final class FakeEmbedder: Embedder, @unchecked Sendable {
    struct Call: Equatable { var text: String; var title: String?; var hasImage: Bool }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var fail = false
    let dimension = 256
    var calls: [Call] { lock.withLock { _calls } }

    func embedQuery(_ text: String) async throws -> [Float] { unit() }

    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] {
        lock.withLock { _calls.append(Call(text: text, title: title, hasImage: image != nil)) }
        if fail { throw FakeError() }
        return unit()
    }

    private func unit() -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        v[0] = 1
        return v
    }
}

final class FakeLoader: ScreenshotLoading, @unchecked Sendable {
    var fail = false
    func loadScreenshot(relativePath: String) async throws -> CGImage {
        if fail { throw ScreenshotLoadError.notFound }
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

/// イベントを裏で集める。
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TriageEvent] = []
    private var task: Task<Void, Never>?
    var events: [TriageEvent] { lock.withLock { _events } }

    init(_ stream: AsyncStream<TriageEvent>) {
        task = Task { [weak self] in
            for await e in stream { self?.append(e) }
        }
    }

    private func append(_ e: TriageEvent) { lock.withLock { _events.append(e) } }

    /// 条件を満たすまで（最大 timeout 秒）待つ。
    func wait(timeout: TimeInterval = 5, until predicate: ([TriageEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(events) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(events)
    }

    deinit { task?.cancel() }
}
