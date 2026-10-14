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
    /// 入力デバイスの変更後に復旧できず、録音が途中で止まった。
    public var wasInterrupted: Bool

    public static let sampleRate: Double = 16_000

    public init(samples16kMono: [Float], duration: TimeInterval, fileURL: URL? = nil, wasInterrupted: Bool = false) {
        self.samples16kMono = samples16kMono
        self.duration = duration
        self.fileURL = fileURL
        self.wasInterrupted = wasInterrupted
    }
}

/// 文字起こし結果。engine はレコードの annotation.stt_engine に入る。
public struct Transcript: Sendable, Equatable {
    public var text: String
    public var engine: String
    /// 文字起こしにかかった時間の内訳（ログ用。エンジンが出さなければ nil）。レコードには保存しない。
    public var diagnostics: TranscriptDiagnostics?

    public init(text: String, engine: String, diagnostics: TranscriptDiagnostics? = nil) {
        self.text = text
        self.engine = engine
        self.diagnostics = diagnostics
    }
}

/// 文字起こし 1 回の所要時間の内訳（数値だけ。⚠️ 本文・トークン列は持たない）。
///
/// WhisperKit の `TranscriptionTimings` と結果のセグメントから作る。遅かったときに
/// 「門・読み込みの待ち」「エンコーダ」「デコーダのループ」「温度フォールバックの解き直し」のどれに時間が掛かったかを切り分けるためのもの。
public struct TranscriptDiagnostics: Sendable, Equatable, Codable {
    /// 入力音声の長さ（秒）。
    public var audioSeconds: Double
    /// 推論を始めるまでの待ち（モデルの読み込み完了・他の推論の終了を待った時間。秒）。
    public var waitSeconds: Double
    /// エンジン内の全体（WhisperKit の `fullPipeline`。秒）。
    public var pipelineSeconds: Double
    /// メルスペクトログラム（秒）。
    public var logmelSeconds: Double
    /// 音声エンコーダ（秒）。
    public var encodingSeconds: Double
    /// デコーダ（フォールバックの解き直しを含む。秒）。WhisperKit の `decodingLoop` は窓ごとのエンコードも含むので、
    /// そこからメルとエンコーダを引いた値。
    public var decodingSeconds: Double
    /// 品質不足で捨てた解き直しに使った時間（WhisperKit の `decodingFallback`。秒）。
    public var fallbackSeconds: Double
    /// 温度フォールバックの回数（最終結果の温度 ÷ 温度の増分から求める。0 なら 1 回目で採用）。
    /// ⚠️ WhisperKit の `totalDecodingFallbacks` は 1 回目のフォールバックで 0 を入れる（off-by-one）ので使わない。
    public var fallbacks: Int
    /// 採用した結果の温度（窓が複数あれば最大）。
    public var temperature: Double
    /// デコーダの反復回数（≒ 生成したトークン数。フォールバックで捨てた分を含む）。
    public var decodingLoops: Int
    /// 処理した窓の数（WhisperKit の `totalDecodingWindows`。フォールバックの解き直しも数える）。
    public var windows: Int
    /// 推論開始から最初のトークンまで（秒。取れなければ nil）。
    public var firstTokenSeconds: Double?
    /// 採用した結果の平均対数確率の最小値（窓が複数あれば最小。`logProbThreshold` との比較用）。
    public var avgLogProb: Double?
    /// 採用した結果の圧縮率の最大値（`compressionRatioThreshold` との比較用）。
    public var compressionRatio: Double?

    public init(
        audioSeconds: Double,
        waitSeconds: Double,
        pipelineSeconds: Double,
        logmelSeconds: Double,
        encodingSeconds: Double,
        decodingSeconds: Double,
        fallbackSeconds: Double,
        fallbacks: Int,
        temperature: Double,
        decodingLoops: Int,
        windows: Int,
        firstTokenSeconds: Double? = nil,
        avgLogProb: Double? = nil,
        compressionRatio: Double? = nil
    ) {
        self.audioSeconds = audioSeconds
        self.waitSeconds = waitSeconds
        self.pipelineSeconds = pipelineSeconds
        self.logmelSeconds = logmelSeconds
        self.encodingSeconds = encodingSeconds
        self.decodingSeconds = decodingSeconds
        self.fallbackSeconds = fallbackSeconds
        self.fallbacks = fallbacks
        self.temperature = temperature
        self.decodingLoops = decodingLoops
        self.windows = windows
        self.firstTokenSeconds = firstTokenSeconds
        self.avgLogProb = avgLogProb
        self.compressionRatio = compressionRatio
    }

    /// ログ 1 行に載せる要約（例: `wait 0ms pipeline 1555ms mel 9ms enc 1166ms dec 375ms fallback 0 (0ms) temp 0.0 loops 32 windows 1 first 1194ms logprob -0.05 cr 1.08`）。
    public var logSummary: String {
        func ms(_ s: Double) -> String { String(format: "%.0fms", s * 1000) }
        var parts = [
            "wait \(ms(waitSeconds))",
            "pipeline \(ms(pipelineSeconds))",
            "mel \(ms(logmelSeconds))",
            "enc \(ms(encodingSeconds))",
            "dec \(ms(decodingSeconds))",
            "fallback \(fallbacks) (\(ms(fallbackSeconds)))",
            String(format: "temp %.1f", temperature),
            "loops \(decodingLoops)",
            "windows \(windows)",
        ]
        if let firstTokenSeconds { parts.append("first \(ms(firstTokenSeconds))") }
        if let avgLogProb { parts.append(String(format: "logprob %.2f", avgLogProb)) }
        if let compressionRatio { parts.append(String(format: "cr %.2f", compressionRatio)) }
        return parts.joined(separator: " ")
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
