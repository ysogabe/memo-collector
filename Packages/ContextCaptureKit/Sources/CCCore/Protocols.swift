import CoreGraphics
import Foundation

// 各担当の実装が満たす契約（計画書 §3）。すべて Sendable・async。
// アプリ（AppCoordinator）とテストはこのプロトコル越しに使い、フェイク実装に差し替えられるようにする。

/// 前面アプリ・ウインドウ・URL・スクショを取る（CCCapture）。
public protocol ContextCapturing: Sendable {
    /// **失敗しない**。権限不足などで取れなかった項目は nil にして返す。
    func captureFrontmost() async -> CaptureContext
}

/// Push-to-Talk の録音（CCCapture）。16kHz モノラル。
public protocol AudioRecording: Sendable {
    /// 録音を始める。マイク権限が無い・デバイスが無いときは throw。録音中に呼んだら何もしない。
    func start() async throws
    /// 録音を止めて結果を返す。録音していなければ throw。
    func stop() async throws -> RecordedAudio
    /// 録音を止めて破棄する（0.3 秒未満の押下・取り消し用）。録音していなければ何もしない。
    func cancel() async
    /// HUD の波形用の入力レベル（0–1、おおむね 20Hz）。録音停止で終わる。呼ぶたびに新しいストリーム。
    func levels() async -> AsyncStream<Float>
}

/// 日本語 STT（CCSTT）。
public protocol SpeechTranscribing: Sendable {
    /// モデルを読み込む（初回は ANE 特殊化で数十秒かかる。オンボーディング中に呼ぶ）。何度呼んでもよい。
    func prepare() async throws
    /// 16kHz モノラルのサンプルを文字起こしする。`vocabulary` は固有名詞辞書（効かない実装もある）。
    func transcribe(samples: [Float], vocabulary: [String]) async throws -> Transcript
}

/// 注釈テキストから意図と日時言及を推定する（CCIntent）。未分類判定は `resolveIntent` に従う。
public protocol IntentClassifying: Sendable {
    func classify(text: String) async throws -> TriageResult
}

/// テキスト・画像の埋め込み（CCEmbedding）。出力は L2 正規化済みで `dimension`（256）次元。
/// 名前は MLXNN.Embedding との衝突を避けて `Embedder`。
public protocol Embedder: Sendable {
    /// 出力次元（MVP は 256）。
    var dimension: Int { get }
    /// 検索クエリ（自然文）の埋め込み。
    func embedQuery(_ text: String) async throws -> [Float]
    /// 記録 1 件の埋め込み（注釈 text・タイトル等 title・スクショ image の融合）。image が nil ならテキストのみ。
    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float]
}

/// スクショ中の秘密情報を検出する（CCGuard）。
public protocol SecretScanning: Sendable {
    /// bbox は正規化座標（0–1、左上原点）。検出なしなら空配列。
    func scan(image: CGImage) async throws -> [SecretFinding]
}

/// メモリ上のモデルを解放できるもの（d1 は 10 分無使用で解放）。
public protocol ModelUnloadable: Sendable {
    /// 解放する。次に使うときに読み直す。読み込んでいなければ何もしない。
    func unload() async
    /// 今メモリに載っているか。
    var isLoaded: Bool { get async }
}

/// レコードと添付の永続化（CCStore）。削除は UI からのみ使い、MCP からは呼ばない。
public protocol RecordStore: Sendable {
    /// 新規保存。同じ id が既にあれば throw。
    func insert(_ record: ContextRecord) async throws
    /// 全フィールドを上書き保存。id が無ければ throw。
    func update(_ record: ContextRecord) async throws
    /// 無ければ nil。
    func get(id: String) async throws -> ContextRecord?
    /// 絞り込み一覧（captured_at の新しい順）。
    func list(_ filter: InboxFilter) async throws -> [ContextRecord]
    /// 絞り込みの件数（limit / offset は無視）。メニューバーの未処理件数に使う。
    func count(_ filter: InboxFilter) async throws -> Int
    /// レコードと添付ファイル・埋め込みを消す。無ければ何もしない。
    func delete(id: String) async throws
    /// 検索用ベクトル（L2 正規化済み）を保存・置換する。
    func setEmbedding(id: String, vector: [Float]) async throws
    /// ベクトルに近い順に最大 limit 件。埋め込みの無いレコードは対象外。
    func search(vector: [Float], limit: Int) async throws -> [SearchHit]
    /// 添付を書き込み、データルートからの相対パス（`CCPaths.attachmentRelativePath`）を返す。レコードは更新しない。
    func writeAttachment(_ data: Data, id: String, kind: AttachmentKind, ext: String, capturedAt: Date) async throws -> String
    /// 相対パスを絶対 URL にする（ファイルの存在は確かめない）。
    func attachmentURL(for relativePath: String) async throws -> URL
}

// MARK: - 追加の契約（Wave 5。既存のプロトコルに必須要件を足すとアプリのフェイク実装が壊れるので、別プロトコルにする）

/// 使う前に読み込み・初回コンパイル（ANE 特殊化など）を済ませられるもの。
/// `CoreMLEmbedder`・`WhisperKitTranscriber`・`D1IntentClassifier` が準拠する。
/// オンボーディングや起動後のバックグラウンドで呼ぶ。何度呼んでもよい（済んでいれば速く返る）。
public protocol ModelPreparable: Sendable {
    func prepare() async throws
}

/// トランザクション内の read-modify-write（`SQLiteRecordStore.modify`）。
/// 最新を読み直して `transform` で書き換え、同じトランザクションで保存する（別プロセスとの同時更新で変更が失われない）。
/// id が無ければ throw。`transform` で id を変えても元の id のまま保存される。
public protocol RecordModifying: Sendable {
    @discardableResult
    func modify(id: String, _ transform: @escaping @Sendable (inout ContextRecord) throws -> Void) async throws -> ContextRecord
}

/// 埋め込み（検索用ベクトル）の有無を調べる。
///
/// どちらも既定実装があるので、`RecordStore` の実装は宣言するだけで準拠できる（フェイク向け）。
/// 既定実装は「零ベクトルで全件検索すると埋め込みのあるレコードが全部返る」ことを使う O(N) の代用。
/// `SQLiteRecordStore` は SQL で直接引く実装を持つ。
public protocol EmbeddingPresenceChecking: Sendable {
    /// 埋め込みを持つレコード id の集合。
    func idsWithEmbedding(dimension: Int) async throws -> Set<String>
    /// 埋め込みを持たないレコード id の集合（起動時のインデックス再開用）。
    func idsWithoutEmbedding(dimension: Int) async throws -> Set<String>
}

extension EmbeddingPresenceChecking where Self: RecordStore {
    public func idsWithEmbedding(dimension: Int) async throws -> Set<String> {
        let total = try await count(InboxFilter(statuses: []))
        guard total > 0 else { return [] }
        let hits = try await search(vector: [Float](repeating: 0, count: dimension), limit: total)
        return Set(hits.map(\.record.id))
    }

    public func idsWithoutEmbedding(dimension: Int) async throws -> Set<String> {
        let total = try await count(InboxFilter(statuses: []))
        guard total > 0 else { return [] }
        let all = try await list(InboxFilter(statuses: [], limit: total)).map(\.id)
        return Set(all).subtracting(try await idsWithEmbedding(dimension: dimension))
    }
}

/// 状態で絞ったベクトル検索。絞り込みは上位 `limit` 件を選ぶ**前**に効く
/// （後から絞ると archived が多いときに件数が足りなくなるため）。
public protocol StatusFilteredSearching: Sendable {
    /// `statuses` の状態のレコードだけを対象に、ベクトルに近い順に最大 limit 件。空集合なら全状態（`InboxFilter.statuses` と同じ）。
    /// 埋め込みの無いレコードは対象外。
    func search(vector: [Float], limit: Int, statuses: Set<RecordStatus>) async throws -> [SearchHit]
}

/// 「モデルが未準備」を表せるエラー（Wave 6）。
///
/// モデルのファイルが無い・読み込みや初回最適化の途中、のように**待てば直る**失敗を、本当の失敗と区別するために使う。
/// トリアージ（CCTriage）はこれが `true` のエラーを失敗にせず `.skipped(.notReady)` にする
/// （書き込まないので、モデルが揃った後の `resumePending()` がそのステップを拾う）。
/// enum のエラーは一部の case だけが未準備のことがあるので、型ではなくこのプロパティで判定する。
public protocol ModelReadinessReporting: Error {
    /// モデルが未準備のための失敗か。
    var isModelNotReady: Bool { get }
}
