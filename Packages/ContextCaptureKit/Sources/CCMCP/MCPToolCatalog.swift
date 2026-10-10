import CCCore
import MCP

/// MCP で公開するツールの名前（PRD §9）。**削除系のツールは意図的に存在しない**（記録の削除はエージェントに許さない）。
public enum CCMCPToolName: String, CaseIterable, Sendable {
    case listInbox = "list_inbox"
    case searchCaptures = "search_captures"
    case getCapture = "get_capture"
    case addNote = "add_note"
    case markDone = "mark_done"
    case archive = "archive"
}

/// ツール定義（名前・説明・入力スキーマ）とサーバーの instructions。
public enum CCMCPToolCatalog {
    /// `list_inbox` / `search_captures` の limit の上限。
    public static let maxLimit = 50
    public static let defaultListLimit = 20
    public static let defaultSearchLimit = 10
    /// `search_captures` の query の最大文字数。
    public static let maxQueryLength = 1000
    /// `add_note` の text の最大文字数。
    public static let maxNoteLength = 4000

    /// `list_inbox` の intent に指定できる値（Intent の 5 種 + 未分類）。
    public static let intentFilterValues: [String] = Intent.allCases.map(\.rawValue) + ["unclassified"]

    /// サーバー情報の instructions（クライアントがシステムプロンプトに入れうる短い説明）。
    public static let instructions = """
    Context Capture は、ユーザーがホットキーで残した「画面のスクショ + 声の注釈 + 前面アプリ/URL」の記録置き場です。
    - まず list_inbox（未処理の一覧、新しい順）か search_captures（自然文検索）で記録を探し、get_capture で 1 件の詳細を読みます。
    - 注釈（annotation）がユーザーの依頼文です。intent は自動推定（code/todo/research/note/schedule、未分類は null）。
    - 調べた結果や作業へのリンクは add_note で記録に追記し、片付いたら mark_done、不要なら archive にします。
    - 記録の削除はできません。
    - 画像は秘密情報チェックが済んだもの（guard_status が clear、またはマスク版がある masked）だけ get_capture(include_image=true) で渡します。
      needs_review（確認待ち）と pending（未チェック）の画像は返しません。ユーザーにアプリの Inbox で確認するよう伝えてください。
    - 入力が不正なときは JSON-RPC のエラー、id の記録が無いときはツール結果の isError で返します。
    """

    static let idProperty: Value = .object([
        "type": "string",
        "description": "記録の id（ULID、26 文字の Crockford Base32。list_inbox / search_captures の結果の id）",
        "pattern": "^[0-7][0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{25}$",
        "minLength": 26,
        "maxLength": 26,
    ])

    static func limitProperty(default def: Int) -> Value {
        .object([
            "type": "integer",
            "description": "返す最大件数（1〜\(maxLimit)、既定 \(def)）",
            "minimum": 1,
            "maximum": .int(maxLimit),
            "default": .int(def),
        ])
    }

    /// 6 ツールの定義。
    public static let tools: [Tool] = [
        Tool(
            name: CCMCPToolName.listInbox.rawValue,
            title: "Inbox の一覧",
            description: """
            未処理（status=inbox）の記録を撮影日時の新しい順に返す。各件に id・撮影日時・アプリ・ウインドウタイトル・URL・注釈（ユーザーの依頼文）・\
            推定した意図（未分類は intent=null と確信度）・日時の言及・秘密情報ガードの状態・画像を渡せるか（image_available）を含む。
            """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "since": .object([
                        "type": "string",
                        "format": "date-time",
                        "description": "この日時以降に撮影したものだけ（ISO 8601。例 2026-10-10T00:00:00+09:00。日付だけ 2026-10-10 ならローカル時刻の 0 時）",
                    ]),
                    "intent": .object([
                        "type": "string",
                        "enum": .array(intentFilterValues.map { .string($0) }),
                        "description": "意図で絞る。unclassified は未分類（確信度不足）のもの",
                    ]),
                    "limit": limitProperty(default: defaultListLimit),
                ]),
                "additionalProperties": false,
            ]),
            annotations: .init(title: "Inbox の一覧", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: CCMCPToolName.searchCaptures.rawValue,
            title: "記録の検索",
            description: """
            自然文で記録を探す。埋め込みが使えればベクトル検索（mode=vector）、使えなければ注釈・ウインドウタイトル・URL の部分一致（mode=keyword、\
            空白区切りの語をすべて含むもの）。archived の記録は既定で除外する。
            """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object([
                        "type": "string",
                        "minLength": 1,
                        "maxLength": .int(maxQueryLength),
                        "description": "探したい内容（自然文またはキーワード）",
                    ]),
                    "limit": limitProperty(default: defaultSearchLimit),
                    "include_archived": .object([
                        "type": "boolean",
                        "default": false,
                        "description": "true なら archived の記録も対象にする",
                    ]),
                ]),
                "required": ["query"],
                "additionalProperties": false,
            ]),
            annotations: .init(title: "記録の検索", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: CCMCPToolName.getCapture.rawValue,
            title: "記録 1 件の詳細",
            description: """
            記録 1 件の詳細（JSON）と Markdown を返す。include_image=true のとき、秘密情報チェックが済んだ画像だけを返す\
            （clear は元画像、masked はマスク版。needs_review / pending は返さず理由をテキストで返す）。
            """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": idProperty,
                    "include_image": .object([
                        "type": "boolean",
                        "default": false,
                        "description": "true ならスクショ画像も返す（渡してよい状態のときだけ）",
                    ]),
                ]),
                "required": ["id"],
                "additionalProperties": false,
            ]),
            annotations: .init(title: "記録 1 件の詳細", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: CCMCPToolName.addNote.rawValue,
            title: "メモを追記",
            description: "記録にメモを追記する（調査結果・PR のリンクなど）。書き手はクライアント名で記録される。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": idProperty,
                    "text": .object([
                        "type": "string",
                        "minLength": 1,
                        "maxLength": .int(maxNoteLength),
                        "description": "追記する本文（\(maxNoteLength) 文字まで）",
                    ]),
                ]),
                "required": ["id", "text"],
                "additionalProperties": false,
            ]),
            annotations: .init(title: "メモを追記", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: CCMCPToolName.markDone.rawValue,
            title: "完了にする",
            description: "記録を完了（status=done）にする。Inbox から消える。",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["id": idProperty]),
                "required": ["id"],
                "additionalProperties": false,
            ]),
            annotations: .init(title: "完了にする", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: CCMCPToolName.archive.rawValue,
            title: "アーカイブする",
            description: "記録をアーカイブ（status=archived）にする。削除ではない（ユーザーはアプリから戻せる）。",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["id": idProperty]),
                "required": ["id"],
                "additionalProperties": false,
            ]),
            annotations: .init(title: "アーカイブする", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
    ]
}
