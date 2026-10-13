import CCCore
import Foundation

/// ツール結果の JSON（キーは snake_case）。エージェントが読むのでフィールド名は自明なものにする。

/// 一覧・検索の 1 件。
struct CaptureSummary: Encodable {
    var id: String
    var capturedAt: Date
    var status: String
    var app: String
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    var annotation: String
    var intent: String?
    /// 未分類（triage はあるが intent が nil）なら true。triage 未実行なら nil。
    var intentUnclassified: Bool?
    var intentConfidence: Double?
    var mentionsDatetime: Bool?
    /// トリアージがまだなら false。
    var triaged: Bool
    var guardStatus: String
    var hasScreenshot: Bool
    /// get_capture(include_image=true) で画像を返せるか。
    var imageAvailable: Bool
    var notesCount: Int
    /// 検索のときだけ（ベクトル検索のコサイン類似度）。
    var score: Double?

    init(_ r: ContextRecord, score: Float? = nil) {
        id = r.id
        capturedAt = r.capturedAt
        status = r.status.rawValue
        app = r.app.name
        bundleID = r.app.bundleID
        windowTitle = r.window?.title
        url = r.url
        annotation = r.annotation.text
        intent = r.triage?.intent?.rawValue
        intentUnclassified = r.triage.map { $0.intent == nil }
        intentConfidence = r.triage.map { ($0.intentConfidence * 1000).rounded() / 1000 }
        mentionsDatetime = r.triage?.mentionsDatetime
        triaged = r.triage != nil
        guardStatus = r.guardInfo.status.rawValue
        hasScreenshot = r.screenshotPath != nil
        imageAvailable = RecordMarkdown.handoffScreenshotPath(r) != nil
        notesCount = r.notes.count
        self.score = score.map { (Double($0) * 10000).rounded() / 10000 }
    }

    enum CodingKeys: String, CodingKey {
        case id, status, app, url, annotation, intent, triaged, score
        case capturedAt = "captured_at"
        case bundleID = "bundle_id"
        case windowTitle = "window_title"
        case intentUnclassified = "intent_unclassified"
        case intentConfidence = "intent_confidence"
        case mentionsDatetime = "mentions_datetime"
        case guardStatus = "guard_status"
        case hasScreenshot = "has_screenshot"
        case imageAvailable = "image_available"
        case notesCount = "notes_count"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(status, forKey: .status)
        try c.encode(app, forKey: .app)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(windowTitle, forKey: .windowTitle)
        try c.encode(url, forKey: .url)
        try c.encode(annotation, forKey: .annotation)
        try c.encode(intent, forKey: .intent)
        try c.encode(intentUnclassified, forKey: .intentUnclassified)
        try c.encode(intentConfidence, forKey: .intentConfidence)
        try c.encode(mentionsDatetime, forKey: .mentionsDatetime)
        try c.encode(triaged, forKey: .triaged)
        try c.encode(guardStatus, forKey: .guardStatus)
        try c.encode(hasScreenshot, forKey: .hasScreenshot)
        try c.encode(imageAvailable, forKey: .imageAvailable)
        try c.encode(notesCount, forKey: .notesCount)
        try c.encodeIfPresent(score, forKey: .score)
    }
}

struct ListInboxOutput: Encodable {
    var count: Int
    /// 条件に合う総数（limit で切る前）。
    var total: Int
    var items: [CaptureSummary]
}

struct SearchOutput: Encodable {
    /// "vector"（埋め込み検索）か "keyword"（部分一致）。
    var mode: String
    /// keyword になった理由（"embedder_unavailable" / "embedder_warming"（検索モデルの読み込み中。少し後なら vector になる）/
    /// "embedder_failed"）。vector なら nil。
    var fallbackReason: String?
    var query: String
    var count: Int
    var items: [CaptureSummary]

    enum CodingKeys: String, CodingKey {
        case mode, query, count, items
        case fallbackReason = "fallback_reason"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(fallbackReason, forKey: .fallbackReason)
        try c.encode(query, forKey: .query)
        try c.encode(count, forKey: .count)
        try c.encode(items, forKey: .items)
    }
}

/// get_capture の詳細。添付のパスは出さない（エージェントはファイルを直接読めない前提。画像は image コンテンツで渡す）。
struct CaptureDetail: Encodable {
    struct NoteOut: Encodable { var author: String; var text: String; var at: Date }
    struct HandoffOut: Encodable { var to: String; var via: String; var at: Date }
    struct TriageOut: Encodable {
        var intent: String?
        var intentConfidence: Double
        var intentProbabilities: [String: Double]?
        var mentionsDatetime: Bool
        var datetimeProbability: Double?
        var model: String
        enum CodingKeys: String, CodingKey {
            case intent, model
            case intentConfidence = "intent_confidence"
            case intentProbabilities = "intent_probabilities"
            case mentionsDatetime = "mentions_datetime"
            case datetimeProbability = "datetime_probability"
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(intent, forKey: .intent)
            try c.encode(intentConfidence, forKey: .intentConfidence)
            try c.encodeIfPresent(intentProbabilities, forKey: .intentProbabilities)
            try c.encode(mentionsDatetime, forKey: .mentionsDatetime)
            try c.encodeIfPresent(datetimeProbability, forKey: .datetimeProbability)
            try c.encode(model, forKey: .model)
        }
    }

    var summary: CaptureSummary
    var extra: [String: String]
    var annotationEdited: Bool
    var sttEngine: String?
    var triage: TriageOut?
    /// 検出された秘密情報の種類（位置や中身は出さない）。
    var guardFindingKinds: [String]
    var notes: [NoteOut]
    var handoffs: [HandoffOut]
    /// この応答に画像を含めたか。
    var imageIncluded: Bool
    /// 画像を含めなかった理由（include_image=true のときだけ）。
    var imageOmittedReason: String?

    enum CodingKeys: String, CodingKey {
        case extra, triage, notes, handoffs
        case annotationEdited = "annotation_edited"
        case sttEngine = "stt_engine"
        case guardFindingKinds = "guard_finding_kinds"
        case imageIncluded = "image_included"
        case imageOmittedReason = "image_omitted_reason"
    }

    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(extra, forKey: .extra)
        try c.encode(annotationEdited, forKey: .annotationEdited)
        try c.encode(sttEngine, forKey: .sttEngine)
        try c.encode(triage, forKey: .triage)
        try c.encode(guardFindingKinds, forKey: .guardFindingKinds)
        try c.encode(notes, forKey: .notes)
        try c.encode(handoffs, forKey: .handoffs)
        try c.encode(imageIncluded, forKey: .imageIncluded)
        try c.encodeIfPresent(imageOmittedReason, forKey: .imageOmittedReason)
    }

    init(_ r: ContextRecord, imageIncluded: Bool, imageOmittedReason: String?) {
        summary = CaptureSummary(r)
        extra = r.extra
        annotationEdited = r.annotation.edited
        sttEngine = r.annotation.sttEngine
        triage = r.triage.map { t in
            TriageOut(
                intent: t.intent?.rawValue,
                intentConfidence: t.intentConfidence,
                intentProbabilities: t.intentProbabilities.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) },
                mentionsDatetime: t.mentionsDatetime,
                datetimeProbability: t.datetimeProbability,
                model: t.model
            )
        }
        guardFindingKinds = Array(Set(r.guardInfo.findings.map(\.kind))).sorted()
        notes = r.notes.map { NoteOut(author: $0.author, text: $0.text, at: $0.at) }
        handoffs = r.handoffs.map { HandoffOut(to: $0.to, via: $0.via, at: $0.at) }
        self.imageIncluded = imageIncluded
        self.imageOmittedReason = imageOmittedReason
    }
}

struct AddNoteOutput: Encodable {
    var id: String
    var notesCount: Int
    var note: CaptureDetail.NoteOut
    enum CodingKeys: String, CodingKey {
        case id, note
        case notesCount = "notes_count"
    }
}

struct StatusOutput: Encodable {
    var id: String
    var status: String
    var previousStatus: String
    enum CodingKeys: String, CodingKey {
        case id, status
        case previousStatus = "previous_status"
    }
}
