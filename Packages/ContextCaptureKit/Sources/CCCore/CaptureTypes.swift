import CoreGraphics
import Foundation

/// ホットキー押下時点で取れた前面コンテキスト（F-03, F-04）。取れなかった項目は nil。
/// 画像は `CGImage` で受け渡す（エンコード・保存は呼び出し側 / CCStore）。
public struct CaptureContext: @unchecked Sendable {
    // CGImage は不変オブジェクトなので複数スレッドから読んでよい（そのため @unchecked Sendable）。

    /// 押下時刻。レコードの captured_at になる。
    public var capturedAt: Date
    /// 前面アプリ。特定できなければ nil（保存時は `AppInfo.unknown`）。
    public var app: AppInfo?
    public var window: WindowInfo?
    /// ブラウザ（Safari / Chrome / Arc / Edge）の URL。
    public var url: String?
    /// 前面ウインドウのスクショ（失敗時は画面全体、それも失敗なら nil）。除外アプリ（F-13）のときも nil。
    public var screenshot: CGImage?
    /// スクショが無い理由（"excluded_app", "permission_denied", "capture_failed" など。ログと UI 表示用）。
    public var screenshotSkipReason: String?
    /// P1 用の追加コンテキスト。
    public var extra: [String: String]

    public init(
        capturedAt: Date = Date(),
        app: AppInfo? = nil,
        window: WindowInfo? = nil,
        url: String? = nil,
        screenshot: CGImage? = nil,
        screenshotSkipReason: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.capturedAt = capturedAt
        self.app = app
        self.window = window
        self.url = url
        self.screenshot = screenshot
        self.screenshotSkipReason = screenshotSkipReason
        self.extra = extra
    }
}

/// 録音結果。`samples16kMono` は 16kHz モノラル Float32（STT にそのまま渡す）。
public struct RecordedAudio: Sendable, Equatable {
    public var samples16kMono: [Float]
    /// 秒。
    public var duration: TimeInterval
    /// 一時ファイルに書いた場合の場所（保存時に添付へ移す）。書いていなければ nil。
    public var fileURL: URL?

    public static let sampleRate: Double = 16_000

    public init(samples16kMono: [Float], duration: TimeInterval, fileURL: URL? = nil) {
        self.samples16kMono = samples16kMono
        self.duration = duration
        self.fileURL = fileURL
    }
}

/// 文字起こし結果。engine はレコードの annotation.stt_engine に入る。
public struct Transcript: Sendable, Equatable {
    public var text: String
    public var engine: String

    public init(text: String, engine: String) {
        self.text = text
        self.engine = engine
    }
}

/// Inbox 一覧の絞り込み。各条件は AND。nil は「条件なし」。並びは captured_at の新しい順。
public struct InboxFilter: Sendable, Equatable {
    /// 対象の状態（既定は inbox のみ）。空集合なら全状態。
    public var statuses: Set<RecordStatus>
    /// 意図での絞り込み。
    public var intent: Intent?
    /// true なら未分類（triage はあるが intent が nil）のみ。`intent` と同時指定は不可（空になる）。
    public var unclassifiedOnly: Bool
    /// この時刻以降（含む）に撮影されたもの。
    public var since: Date?
    /// この時刻より前に撮影されたもの。
    public var until: Date?
    /// ガード状態での絞り込み。
    public var guardStatuses: Set<GuardStatus>?
    public var limit: Int
    public var offset: Int

    public init(
        statuses: Set<RecordStatus> = [.inbox],
        intent: Intent? = nil,
        unclassifiedOnly: Bool = false,
        since: Date? = nil,
        until: Date? = nil,
        guardStatuses: Set<GuardStatus>? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.statuses = statuses
        self.intent = intent
        self.unclassifiedOnly = unclassifiedOnly
        self.since = since
        self.until = until
        self.guardStatuses = guardStatuses
        self.limit = limit
        self.offset = offset
    }

    /// 未処理（inbox）の新しい順 50 件。
    public static let inbox = InboxFilter()
}

/// ベクトル検索の 1 件。score はコサイン類似度（大きいほど近い）。
public struct SearchHit: Sendable, Equatable {
    public var record: ContextRecord
    public var score: Float

    public init(record: ContextRecord, score: Float) {
        self.record = record
        self.score = score
    }
}
