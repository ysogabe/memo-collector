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
