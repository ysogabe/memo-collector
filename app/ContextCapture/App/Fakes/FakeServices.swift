import CCCore
import Foundation

// MARK: - 検索

/// 文字の 2-gram の重なりで近さを測る、それらしい検索（本物は埋め込みのコサイン類似度）。
struct FakeSearchService: SearchServing {
    let store: any RecordStore
    /// フェイクのサンプルだけが持つ「スクショの見た目」の言葉（`ContextRecord.extra` のキー）。
    static let visualKeywordsKey = "fake_visual_keywords"

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let q = Self.bigrams(query)
        guard !q.isEmpty else { return [] }
        let all = try await store.list(InboxFilter(statuses: [], limit: .max))
        return all
            .map { r -> SearchHit in
                // 本物は画像の埋め込みで「見た目」も探す。フェイクは extra の見た目キーワードで代用する。
                let doc = Self.bigrams([r.annotation.text, r.window?.title ?? "", r.url ?? "", r.app.name,
                                        r.extra[FakeSearchService.visualKeywordsKey] ?? ""].joined(separator: " "))
                let score = Float(q.intersection(doc).count) / Float(q.count)
                return SearchHit(record: r, score: score)
            }
            .filter { $0.score > 0.15 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.lowercased().filter { !$0.isWhitespace && !"、。・—-".contains($0) })
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [String(chars)] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
    }
}

// MARK: - キャプチャ

/// 偽の録音〜保存。メニューの「フェイク操作」から呼ぶ。
final class FakeCaptureController: CaptureControlling, @unchecked Sendable {
    private let store: FakeRecordStore
    private let lock = NSLock()
    private var continuation: AsyncStream<CaptureEvent>.Continuation?

    init(store: FakeRecordStore) {
        self.store = store
    }

    func events() -> AsyncStream<CaptureEvent> {
        AsyncStream { c in
            lock.withLock { continuation = c }
        }
    }

    private func emit(_ e: CaptureEvent) {
        _ = lock.withLock { continuation }?.yield(e)
    }

    func undo(recordID: String) async throws {
        try await store.delete(id: recordID)
    }

    func retryTranscription(recordID: String) async {
        guard var r = try? await store.get(id: recordID) else { return }
        r.annotation = Annotation(text: "もう一度聞き直した文字起こし。仕様のこの部分を確認する", sttEngine: "whisper-large-v3-turbo")
        try? await store.update(r)
        emit(.saved(r, notice: nil))
    }

    /// 2.5 秒話して保存する。
    @MainActor
    func simulateCapture(text: String = "このissueの修正、Claude Codeにやらせて。ストリーミング対応のところ",
                         notice: CaptureNotice? = nil) async {
        await speak(seconds: 2.5)
        var r = ContextRecord(
            capturedAt: Date(),
            app: AppInfo(name: "Google Chrome", bundleID: "com.google.Chrome"),
            window: WindowInfo(title: "Support streaming events · Issue #128", frame: nil),
            url: "https://github.com/opendots/opendots/issues/128",
            annotation: Annotation(text: text, sttEngine: "whisper-large-v3-turbo"),
            guardInfo: GuardInfo(status: .pending)
        )
        if notice != .screenRecordingDenied {
            let rel = CCPaths.attachmentRelativePath(id: r.id, kind: .screenshot, ext: "png", capturedAt: r.capturedAt)
            if MockScreen.browser(title: "Support streaming events #128", url: "github.com/opendots/opendots/issues/128")
                .write(to: store.root.appendingPathComponent(rel), masked: false) {
                r.screenshotPath = rel
            }
        }
        try? await Task.sleep(for: .milliseconds(600))
        do {
            try await store.insert(r)
            emit(.saved(r, notice: notice))
        } catch {
            emit(.failed(.saveFailed(detail: "\(error)")))
        }
    }

    /// 声が入っていない録音。
    @MainActor
    func simulateNoVoice() async {
        await speak(seconds: 1.2, silent: true)
        emit(.failed(.noVoice))
    }

    /// 0.3 秒未満の押下（黙って破棄）。
    @MainActor
    func simulateShortPress() async {
        let (levels, c) = AsyncStream<Float>.makeStream()
        emit(.recordingStarted(levels: levels))
        try? await Task.sleep(for: .milliseconds(200))
        c.finish()
        emit(.recordingDiscarded)
    }

    /// 文字起こしの失敗（音声を残して保存した扱い）。
    @MainActor
    func simulateTranscriptionFailure() async {
        await speak(seconds: 2)
        let r = ContextRecord(
            capturedAt: Date(),
            app: AppInfo(name: "Safari", bundleID: "com.apple.Safari"),
            window: WindowInfo(title: "API リファレンス", frame: nil),
            annotation: Annotation(text: "", sttEngine: nil),
            guardInfo: GuardInfo(status: .pending)
        )
        try? await store.insert(r)
        emit(.failed(.transcriptionFailed(recordID: r.id)))
    }

    @MainActor
    func simulateMicrophoneUnavailable() async {
        emit(.failed(.microphoneUnavailable))
    }

    private func speak(seconds: Double, silent: Bool = false) async {
        let (levels, c) = AsyncStream<Float>.makeStream()
        emit(.recordingStarted(levels: levels))
        let ticks = Int(seconds * 20)
        for i in 0..<ticks {
            let t = Double(i) / 20
            let v = silent ? Float.random(in: 0...0.03) : Float(max(0, min(1, 0.35 + 0.3 * sin(t * 7) + Double.random(in: -0.2...0.3))))
            c.yield(v)
            try? await Task.sleep(for: .milliseconds(50))
        }
        c.finish()
        emit(.recordingEnded)
    }
}

// MARK: - ガード

struct FakeGuardReviewer: GuardReviewing {
    let store: any RecordStore

    func markReviewed(recordID: String) async throws -> ContextRecord {
        guard var r = try await store.get(id: recordID) else { throw FakeStoreError.notFound(recordID) }
        r.guardInfo.status = .clear
        try await store.update(r)
        return r
    }

    /// フェイクではマスク画像を作らず、元画像を指したまま状態だけ `masked` にする（画面上は検出箇所を塗って見せる）。
    func useMaskedImage(recordID: String) async throws -> ContextRecord {
        guard var r = try await store.get(id: recordID) else { throw FakeStoreError.notFound(recordID) }
        r.guardInfo.status = .masked
        r.maskedScreenshotPath = r.maskedScreenshotPath ?? r.screenshotPath
        try await store.update(r)
        return r
    }
}

// MARK: - 権限

/// 「システム設定を開く」を押すと許可済みに切り替わる偽の権限。
actor FakePermissions: PermissionsProviding {
    private var states: [PermissionKind: PermissionState]

    init(states: [PermissionKind: PermissionState] = [
        .microphone: .granted, .screenRecording: .notDetermined, .accessibility: .notDetermined, .automation: .unknown,
    ]) {
        self.states = states
    }

    func state(of kind: PermissionKind) async -> PermissionState { states[kind] ?? .notDetermined }
    func request(_ kind: PermissionKind) async { states[kind] = .granted }
    func openSystemSettings(for kind: PermissionKind) async { states[kind] = .granted }
}

// MARK: - モデルの準備

/// 約 5GB を数秒でダウンロードしたふりをして、最適化の段階も見せる。
struct FakeModelPreparation: ModelPreparationProviding {
    static let totalBytes: Int64 = 5_100_000_000

    func isPrepared() async -> Bool { false }

    func prepare() -> AsyncThrowingStream<ModelPreparationProgress, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                let items = ["文字起こしモデル", "意図の推定モデル", "検索モデル"]
                let steps = 60
                for i in 0...steps {
                    let f = Double(i) / Double(steps)
                    c.yield(ModelPreparationProgress(phase: .downloading, fractionCompleted: f,
                                                     completedBytes: Int64(Double(Self.totalBytes) * f), totalBytes: Self.totalBytes,
                                                     currentItem: items[min(items.count - 1, Int(f * Double(items.count)))]))
                    try await Task.sleep(for: .milliseconds(60))
                }
                for i in 0...20 {
                    c.yield(ModelPreparationProgress(phase: .optimizing, fractionCompleted: Double(i) / 20,
                                                     completedBytes: Self.totalBytes, totalBytes: Self.totalBytes, currentItem: "文字起こしモデル"))
                    try await Task.sleep(for: .milliseconds(80))
                }
                c.yield(ModelPreparationProgress(phase: .finished, fractionCompleted: 1, completedBytes: Self.totalBytes, totalBytes: Self.totalBytes))
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - 設定

/// 保存しない設定（スナップショット用。毎回既定値から始める）。
final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppSettings

    init(_ initial: AppSettings = AppSettings()) {
        value = initial
    }

    func load() -> AppSettings { lock.withLock { value } }
    func save(_ settings: AppSettings) { lock.withLock { value = settings } }
}
