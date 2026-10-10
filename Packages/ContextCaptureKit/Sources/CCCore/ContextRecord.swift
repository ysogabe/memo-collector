import CoreGraphics
import Foundation

/// 1 キャプチャ = 1 レコード（PRD §7）。JSON のキーは PRD の snake_case。
/// 添付（screenshot / masked_screenshot / audio）はデータルートからの相対パス（`CCPaths.attachmentRelativePath`）。
/// PRD に無い追加フィールド（masked_screenshot, notes, triage.datetime_probability など）は省略可能で、PRD の例 JSON をそのまま読める。
public struct ContextRecord: Codable, Sendable, Equatable, Identifiable {
    /// ULID 文字列（`ULID.generate().string`）。
    public var id: String
    public var capturedAt: Date
    public var app: AppInfo
    /// 取れなかったときは nil。
    public var window: WindowInfo?
    /// ブラウザで取れたときだけ。
    public var url: String?
    /// P1 用の追加コンテキスト（file_path, line, cwd …）。
    public var extra: [String: String]
    public var screenshotPath: String?
    /// 秘密情報をマスクした版（guard.status == masked のとき）。
    public var maskedScreenshotPath: String?
    /// 保持期間（既定 7 日）を過ぎたら削除され nil になる。
    public var audioPath: String?
    public var annotation: Annotation
    /// 非同期トリアージで埋まる。未実行なら nil。
    public var triage: TriageResult?
    /// 秘密情報ガードの状態。保存直後は `.pending`。
    public var guardInfo: GuardInfo
    /// 外部（エージェント）への受け渡し履歴。
    public var handoffs: [Handoff]
    /// エージェント／ユーザーの追記（MCP `add_note`）。
    public var notes: [Note]
    public var status: RecordStatus

    public init(
        id: String = ULID.generate().string,
        capturedAt: Date,
        app: AppInfo,
        window: WindowInfo? = nil,
        url: String? = nil,
        extra: [String: String] = [:],
        screenshotPath: String? = nil,
        maskedScreenshotPath: String? = nil,
        audioPath: String? = nil,
        annotation: Annotation,
        triage: TriageResult? = nil,
        guardInfo: GuardInfo = GuardInfo(),
        handoffs: [Handoff] = [],
        notes: [Note] = [],
        status: RecordStatus = .inbox
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.app = app
        self.window = window
        self.url = url
        self.extra = extra
        self.screenshotPath = screenshotPath
        self.maskedScreenshotPath = maskedScreenshotPath
        self.audioPath = audioPath
        self.annotation = annotation
        self.triage = triage
        self.guardInfo = guardInfo
        self.handoffs = handoffs
        self.notes = notes
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case app, window, url, extra
        case screenshotPath = "screenshot"
        case maskedScreenshotPath = "masked_screenshot"
        case audioPath = "audio"
        case annotation, triage
        case guardInfo = "guard"
        case handoffs = "handoff"
        case notes, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        app = try c.decode(AppInfo.self, forKey: .app)
        window = try c.decodeIfPresent(WindowInfo.self, forKey: .window)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        extra = try c.decodeIfPresent([String: String].self, forKey: .extra) ?? [:]
        screenshotPath = try c.decodeIfPresent(String.self, forKey: .screenshotPath)
        maskedScreenshotPath = try c.decodeIfPresent(String.self, forKey: .maskedScreenshotPath)
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        annotation = try c.decode(Annotation.self, forKey: .annotation)
        triage = try c.decodeIfPresent(TriageResult.self, forKey: .triage)
        guardInfo = try c.decodeIfPresent(GuardInfo.self, forKey: .guardInfo) ?? GuardInfo()
        handoffs = try c.decodeIfPresent([Handoff].self, forKey: .handoffs) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        status = try c.decodeIfPresent(RecordStatus.self, forKey: .status) ?? .inbox
    }

    /// nil の項目も `null` で書く（PRD の例と同じく、キーの有無で意味が変わらないようにする）。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(app, forKey: .app)
        try c.encode(window, forKey: .window)
        try c.encode(url, forKey: .url)
        try c.encode(extra, forKey: .extra)
        try c.encode(screenshotPath, forKey: .screenshotPath)
        try c.encode(maskedScreenshotPath, forKey: .maskedScreenshotPath)
        try c.encode(audioPath, forKey: .audioPath)
        try c.encode(annotation, forKey: .annotation)
        try c.encode(triage, forKey: .triage)
        try c.encode(guardInfo, forKey: .guardInfo)
        try c.encode(handoffs, forKey: .handoffs)
        try c.encode(notes, forKey: .notes)
        try c.encode(status, forKey: .status)
    }
}

/// 前面アプリ。F-04 で必須。取れなかったときは `AppInfo.unknown`。
public struct AppInfo: Codable, Sendable, Equatable, Hashable {
    public var name: String
    /// 取れなかったときは nil。
    public var bundleID: String?

    public init(name: String, bundleID: String?) {
        self.name = name
        self.bundleID = bundleID
    }

    /// 前面アプリを特定できなかったときの値。
    public static let unknown = AppInfo(name: "Unknown", bundleID: nil)

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
    }
}

/// フォーカス中のウインドウ。frame はスクリーン座標（ポイント、`[x, y, w, h]`）。
public struct WindowInfo: Codable, Sendable, Equatable {
    public var title: String?
    public var frame: CGRect?

    public init(title: String?, frame: CGRect?) {
        self.title = title
        self.frame = frame
    }

    enum CodingKeys: String, CodingKey { case title, frame }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        frame = try c.decodeIfPresent(RectArray.self, forKey: .frame)?.rect
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(frame.map(RectArray.init), forKey: .frame)
    }
}

/// 自分の声の注釈。`edited` はユーザーが文字起こしを手直ししたら true。
public struct Annotation: Codable, Sendable, Equatable {
    public var text: String
    /// 文字起こしエンジン名（例: "whisper-large-v3-turbo"）。手入力なら nil。
    public var sttEngine: String?
    public var edited: Bool

    public init(text: String, sttEngine: String?, edited: Bool = false) {
        self.text = text
        self.sttEngine = sttEngine
        self.edited = edited
    }

    enum CodingKeys: String, CodingKey {
        case text
        case sttEngine = "stt_engine"
        case edited
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        sttEngine = try c.decodeIfPresent(String.self, forKey: .sttEngine)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(sttEngine, forKey: .sttEngine)
        try c.encode(edited, forKey: .edited)
    }
}

/// 秘密情報ガードの状態（PRD F-10）。`needs_review` の画像は外部へ渡さない。
public enum GuardStatus: String, Codable, Sendable, CaseIterable, Hashable {
    /// まだスキャンしていない。
    case pending
    /// 検出なし。
    case clear
    /// 検出あり。ユーザーの確認待ち（MCP は画像を返さない）。
    case needsReview = "needs_review"
    /// 検出箇所をマスクした版を作成済み（外部へはマスク版を渡す）。
    case masked

    /// 外部（MCP など）へ画像を渡してよい状態か。
    public var allowsImageHandoff: Bool { self == .clear || self == .masked }
}

/// 秘密情報の検出 1 件。bbox は画像に対する正規化座標（0–1、**左上原点**）`[x, y, w, h]`。
/// 注意: Vision の boundingBox は左下原点なので、CCGuard 側で上下を反転して入れること。
public struct SecretFinding: Codable, Sendable, Equatable, Hashable {
    /// 種別（例: "github_token", "aws_access_key", "openai_api_key", "password"）。集合は CCGuard が決める。
    public var kind: String
    public var bbox: CGRect

    public init(kind: String, bbox: CGRect) {
        self.kind = kind
        self.bbox = bbox
    }

    enum CodingKeys: String, CodingKey { case kind, bbox }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        bbox = try c.decode(RectArray.self, forKey: .bbox).rect
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(RectArray(bbox), forKey: .bbox)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(bbox.origin.x); hasher.combine(bbox.origin.y)
        hasher.combine(bbox.size.width); hasher.combine(bbox.size.height)
    }
}

/// レコードの `guard` 欄。
public struct GuardInfo: Codable, Sendable, Equatable {
    public var status: GuardStatus
    public var findings: [SecretFinding]

    public init(status: GuardStatus = .pending, findings: [SecretFinding] = []) {
        self.status = status
        self.findings = findings
    }

    enum CodingKeys: String, CodingKey { case status, findings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(GuardStatus.self, forKey: .status)
        findings = try c.decodeIfPresent([SecretFinding].self, forKey: .findings) ?? []
    }
}

/// 外部への受け渡し 1 件（例: to "claude-code", via "mcp"）。
public struct Handoff: Codable, Sendable, Equatable {
    public var to: String
    public var at: Date
    public var via: String

    public init(to: String, at: Date, via: String) {
        self.to = to
        self.at = at
        self.via = via
    }
}

/// 追記 1 件。author はエージェント名または "user"。
public struct Note: Codable, Sendable, Equatable {
    public var author: String
    public var text: String
    public var at: Date

    public init(author: String, text: String, at: Date) {
        self.author = author
        self.text = text
        self.at = at
    }
}

/// レコードの処理状態。Inbox に出るのは `.inbox`。
public enum RecordStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case inbox
    case done
    case archived
}
