import CCCapture
import CCCore
import CoreGraphics
import Foundation

/// テスト用の小さなロック付きの箱。
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
    func update<R>(_ body: (inout T) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

enum TestImages {
    static func solid(width: Int = 64, height: Int = 48) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 8, width: 20, height: 10))
        return ctx.makeImage()!
    }
}

/// 前面コンテキストのフェイク。
final class FakeCapturer: ContextCapturing, @unchecked Sendable {
    let context: Box<CaptureContext>
    let calls = Box(0)
    let delay: Duration

    init(context: CaptureContext, delay: Duration = .zero) {
        self.context = Box(context)
        self.delay = delay
    }

    func captureFrontmost() async -> CaptureContext {
        calls.update { $0 += 1 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return context.get()
    }

    static func standard(capturedAt: Date = Date(timeIntervalSince1970: 1_791_000_000.123_456)) -> FakeCapturer {
        FakeCapturer(context: CaptureContext(
            capturedAt: capturedAt,
            app: AppInfo(name: "Google Chrome", bundleID: "com.google.Chrome"),
            window: WindowInfo(title: "Issue #128", frame: CGRect(x: 0, y: 38, width: 1440, height: 862)),
            url: "https://github.com/opendots/opendots/issues/128",
            screenshot: TestImages.solid()
        ))
    }
}

/// 録音のフェイク。呼ばれた順を `log` に残す。
final class FakeRecorder: AudioRecording, @unchecked Sendable {
    let log = Box<[String]>([])
    let startError = Box<Error?>(nil)
    let startDelay = Box<Duration>(.zero)
    let samples = Box<[Float]>(Array(repeating: 0.1, count: 16_000))
    let writesFile = Box(true)
    let recording = Box(false)
    let levelContinuation = Box<AsyncStream<Float>.Continuation?>(nil)
    /// stop で返した一時ファイル。
    let lastFileURL = Box<URL?>(nil)

    func start() async throws {
        log.update { $0.append("start") }
        let d = startDelay.get()
        if d > .zero { try? await Task.sleep(for: d) }
        if let e = startError.get() { throw e }
        recording.set(true)
        levelContinuation.get()?.yield(0.5)
    }

    func stop() async throws -> RecordedAudio {
        log.update { $0.append("stop") }
        guard recording.get() else { throw PushToTalkRecorder.RecorderError.notRecording }
        recording.set(false)
        levelContinuation.get()?.finish()
        let s = samples.get()
        var url: URL?
        if writesFile.get() {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("cc-test-\(UUID().uuidString).wav")
            try AudioFileIO.wavData(samples: s).write(to: u)
            url = u
        }
        lastFileURL.set(url)
        return RecordedAudio(samples16kMono: s, duration: Double(s.count) / 16_000, fileURL: url)
    }

    func cancel() async {
        log.update { $0.append("cancel") }
        recording.set(false)
        levelContinuation.get()?.finish()
    }

    func levels() async -> AsyncStream<Float> {
        log.update { $0.append("levels") }
        let (s, c) = AsyncStream<Float>.makeStream()
        levelContinuation.set(c)
        return s
    }

    var starts: Int { log.get().filter { $0 == "start" }.count }
}

/// 文字起こしのフェイク。
final class FakeTranscriber: SpeechTranscribing, @unchecked Sendable {
    let handler: Box<@Sendable ([Float], [String]) async throws -> Transcript>
    let calls = Box<[[String]]>([])

    init(_ handler: @escaping @Sendable ([Float], [String]) async throws -> Transcript = { _, _ in
        Transcript(text: "このissueの修正、Claude Codeにやらせて", engine: "whisperkit-large-v3-turbo")
    }) {
        self.handler = Box(handler)
    }

    func prepare() async throws {}

    func transcribe(samples: [Float], vocabulary: [String]) async throws -> Transcript {
        calls.update { $0.append(vocabulary) }
        return try await handler.get()(samples, vocabulary)
    }
}

/// メモリ上のストア（添付は一時ディレクトリに実ファイルで書く）。
final class TestStore: RecordStore, @unchecked Sendable {
    let root: URL
    let records = Box<[String: ContextRecord]>([:])
    let insertError = Box<Error?>(nil)

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func insert(_ record: ContextRecord) async throws {
        if let e = insertError.get() { throw e }
        try records.update { r in
            guard r[record.id] == nil else { throw CocoaError(.fileWriteFileExists) }
            r[record.id] = record
        }
    }

    func update(_ record: ContextRecord) async throws {
        try records.update { r in
            guard r[record.id] != nil else { throw CocoaError(.fileNoSuchFile) }
            r[record.id] = record
        }
    }

    func get(id: String) async throws -> ContextRecord? { records.get()[id] }

    func list(_ filter: InboxFilter) async throws -> [ContextRecord] {
        Array(records.get().values.sorted { $0.capturedAt > $1.capturedAt }.prefix(filter.limit))
    }

    func count(_ filter: InboxFilter) async throws -> Int { records.get().count }

    func delete(id: String) async throws {
        guard let r = records.update({ $0.removeValue(forKey: id) }) else { return }
        for p in [r.screenshotPath, r.maskedScreenshotPath, r.audioPath].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(p))
        }
    }

    /// 埋め込み（id → ベクトル）。`search` は内積の大きい順に返す（埋め込みの無い記録は対象外。本物と同じ）。
    let embeddings = Box<[String: [Float]]>([:])
    let searchCalls = Box<[[Float]]>([])

    func setEmbedding(id: String, vector: [Float]) async throws {
        embeddings.update { $0[id] = vector }
    }

    func search(vector: [Float], limit: Int) async throws -> [SearchHit] {
        searchCalls.update { $0.append(vector) }
        let recs = records.get()
        let hits = embeddings.get().compactMap { id, v -> SearchHit? in
            guard let r = recs[id] else { return nil }
            return SearchHit(record: r, score: zip(v, vector).reduce(0) { $0 + $1.0 * $1.1 })
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// `SQLiteRecordStore.modify` と同じ read-modify-write（transform が throw したら書かない）。
    @discardableResult
    func modify(id: String, _ transform: @escaping @Sendable (inout ContextRecord) throws -> Void) async throws -> ContextRecord {
        try records.update { r in
            guard var rec = r[id] else { throw CocoaError(.fileNoSuchFile) }
            try transform(&rec)
            r[id] = rec
            return rec
        }
    }

    func writeAttachment(_ data: Data, id: String, kind: AttachmentKind, ext: String, capturedAt: Date) async throws -> String {
        let rel = CCPaths.attachmentRelativePath(id: id, kind: kind, ext: ext, capturedAt: capturedAt)
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return rel
    }

    func attachmentURL(for relativePath: String) async throws -> URL { root.appendingPathComponent(relativePath) }

    /// captures/ 以下のファイル数。
    func attachmentFileCount() -> Int {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var n = 0
        while let u = e?.nextObject() as? URL {
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { n += 1 }
        }
        return n
    }
}
