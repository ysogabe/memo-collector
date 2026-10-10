import CCCore
import Foundation

// UI が依存する小さなプロトコル（Wave 2 UI 担当が定義）。
// CCCore の `RecordStore` と並んで、画面の ViewModel はここにあるものだけを見る。
// 本物の実装は wiring 担当が `AppEnvironment.live()` で差し込む。フェイクは App/Fakes/。

// MARK: - キャプチャ（HUD / トーストを駆動するイベント源）

/// 録音〜保存の流れで UI に知らせる出来事。HUD とトーストはこれだけを見て動く。
enum CaptureEvent: Sendable {
    /// 録音を始めた。HUD を出し、`levels`（0–1、おおむね 20Hz。`AudioRecording.levels()` をそのまま渡す）で波形を描く。
    case recordingStarted(levels: AsyncStream<Float>)
    /// 録音を止めた（文字起こし・保存へ進む）。HUD を消す。
    case recordingEnded
    /// 0.3 秒未満の押下などで黙って破棄した。HUD を消すだけで何も表示しない。
    case recordingDiscarded
    /// 保存した。トースト「保存しました」を出し、取り消しを受け付ける。
    /// `notice` は保存は続けたが知らせたいこと（画面収録の許可が無くスクショ無しで保存、など）。
    case saved(ContextRecord, notice: CaptureNotice?)
    /// 記録を作らなかった、または不完全に保存した。
    case failed(CaptureFailure)
}

/// 保存はできたが添えて伝えること（PRD §6.3）。
enum CaptureNotice: Sendable, Equatable {
    /// 画面収録の許可が無く、スクショなしで保存した。
    case screenRecordingDenied
}

/// 失敗の種類（PRD §6.3）。文言は `CaptureMessages` が決める。
enum CaptureFailure: Sendable, Equatable {
    /// 無音・短すぎる録音。記録は作らない。
    case noVoice
    /// 文字起こしに失敗した。音声ファイルを残して保存済み（`recordID`）。[再試行] を出す。
    case transcriptionFailed(recordID: String)
    /// マイクが使えない（権限なし・デバイスなし）。
    case microphoneUnavailable
    /// 保存そのものに失敗した（ディスク等）。`detail` はログ用の短い説明。
    case saveFailed(detail: String)
}

/// 録音〜保存の流れを持つもの（本物は wiring 担当の AppCoordinator）。
protocol CaptureControlling: Sendable {
    /// 出来事のストリーム。アプリ全体で 1 か所（`AppModel`）だけが読む。
    func events() -> AsyncStream<CaptureEvent>
    /// 保存直後の記録を取り消す（トーストの [取り消す]）。記録と添付を消し、保存後の処理（トリアージ等）も止める。
    func undo(recordID: String) async throws
    /// 文字起こしをやり直す（トーストの [再試行]）。成功すれば `.saved` を、失敗すればまた `.failed` を流す。
    func retryTranscription(recordID: String) async
}

// MARK: - 検索

/// 自然文の検索（F-11）。本物はクエリを `Embedder.embedQuery` → `RecordStore.search` に流す。
protocol SearchServing: Sendable {
    /// 近い順。該当なしなら空配列。
    func search(_ query: String, limit: Int) async throws -> [SearchHit]
    /// 結果と、添えて見せる一言（埋め込みが使えず文字の一致で探したときなど）。既定は `search` の結果だけ。
    func searchWithNotice(_ query: String, limit: Int) async throws -> SearchResponse
}

extension SearchServing {
    func searchWithNotice(_ query: String, limit: Int) async throws -> SearchResponse {
        SearchResponse(hits: try await search(query, limit: limit), notice: nil)
    }
}

/// 検索の結果。`notice` は結果の見出しの下に出す（nil なら何も出さない）。
struct SearchResponse: Sendable {
    var hits: [SearchHit]
    var notice: String?
}

/// 見た目での検索（埋め込み）が使えるか。メニューバーに出す。
enum SearchReadiness: Sendable, Equatable {
    /// 検索モデルのファイルが無い（モデルの準備がまだ）。
    case unavailable
    /// 読み込みと初回の最適化中（初回は数分）。
    case preparing
    /// 索引を作っている（初回・画像トークン数の変更後）。
    case rebuilding
    case ready
    /// 作り直しは終わったが、一部の記録（failed 件）の埋め込みに失敗した。見た目での検索は使うが、その記録は出ないことがある。
    /// 次の起動（またはモデルの準備後）に失敗分だけやり直す。cc-mcp はこの間ベクトル検索を使わない（状態ファイルが degraded）。
    case degraded(failed: Int)
    /// 読み込めなかった。
    case failed

    /// メニューバーのメニューに出す一言（使えるときは出さない）。
    var menuText: String? {
        switch self {
        case .unavailable: return "検索: モデルが未準備のため文字の一致で探します"
        case .preparing: return "検索の準備中…（初回は数分かかります）"
        case .rebuilding: return "検索の索引を作っています…"
        case .ready: return nil
        case let .degraded(n): return "検索: \(n) 件の記録の索引を作れませんでした（次回の起動でやり直します）"
        case .failed: return "検索: 見た目での検索を使えません（文字の一致で探します）"
        }
    }
}

// MARK: - 保存後の処理（トリアージ: 秘密情報ガード → 意図 → 検索索引）

/// 保存後の非同期処理への依頼口。本物は CCTriage の `TriageQueue`（直列・1 件ずつ）。
protocol TriageQueuing: Sendable {
    /// 新しく保存した記録を全ステップで処理する。
    func enqueue(id: String) async
    /// 注釈を編集した → 意図と索引をやり直す（手で変えた意図は上書きされない）。
    func annotationEdited(id: String) async
    /// 索引だけ作り直す（埋め込みの設定が変わったとき）。
    func reindex(id: String) async
    /// 未完了のステップが残っている記録を古い順に投入し、件数を返す。
    func resumePending() async throws -> Int
    /// キューが空になるまで待つ。
    func waitUntilIdle() async
    /// 索引だけ作り直し、キューが空になるまで待って、**索引できなかった記録の id** を返す（索引の作り直しの完了判定）。
    /// 本物は `TriageQueue.reindexAndWait(ids:)`。既定実装は `reindex` を順に積んで待つだけで、失敗を報告しない（空配列）。
    func reindexAll(ids: [String]) async -> [String]
}

extension TriageQueuing {
    func reindexAll(ids: [String]) async -> [String] {
        for id in ids { await reindex(id: id) }
        await waitUntilIdle()
        return []
    }
}

/// 何もしないキュー（フェイク起動・スナップショット用）。
struct NoopTriageQueue: TriageQueuing {
    func enqueue(id: String) async {}
    func annotationEdited(id: String) async {}
    func reindex(id: String) async {}
    func resumePending() async throws -> Int { 0 }
    func waitUntilIdle() async {}
}

// MARK: - 秘密情報ガードの確認（F-10）

/// 「要確認」の記録に対するユーザーの判断を反映する。マスク画像の生成は CCGuard 担当。
protocol GuardReviewing: Sendable {
    /// ユーザーが確認して問題ないと判断した → `guard.status = clear` にして返す。
    func markReviewed(recordID: String) async throws -> ContextRecord
    /// 検出箇所を塗ったマスク画像を作り、`maskedScreenshotPath` と `guard.status = masked` にして返す。
    func useMaskedImage(recordID: String) async throws -> ContextRecord
}

// MARK: - 設定

/// 設定の読み書き。変更は `SettingsChange.didChangeNotification` で知らせる（wiring がホットキー再登録などに使う）。
protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

enum SettingsChange {
    /// `SettingsStore.save` の後に main スレッドで投げる。object は無し。
    static let didChangeNotification = Notification.Name("ContextCaptureSettingsDidChange")
}

// MARK: - 権限（PRD §8.2）

enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    case microphone
    case screenRecording
    case accessibility
    case automation
    var id: String { rawValue }
}

enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// 確かめる手段が無い（オートメーションはブラウザごとに初回送信時に聞かれる）。
    case unknown
}

protocol PermissionsProviding: Sendable {
    func state(of kind: PermissionKind) async -> PermissionState
    /// システムの許可ダイアログを出す（出せる権限だけ。マイク・画面収録・アクセシビリティ）。
    func request(_ kind: PermissionKind) async
    /// システム設定の該当パネルを開く。
    func openSystemSettings(for kind: PermissionKind) async
}

// MARK: - モデルの準備

struct ModelPreparationProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// ダウンロード中（`completedBytes` / `totalBytes`）。
        case downloading
        /// 初回の最適化（Core ML / ANE の特殊化、d1 の変換など）。
        case optimizing
        case finished
    }
    var phase: Phase
    /// 0–1。
    var fractionCompleted: Double
    var completedBytes: Int64
    var totalBytes: Int64
    /// 今扱っているもの（例: "文字起こしモデル"）。
    var currentItem: String?
}

protocol ModelPreparationProviding: Sendable {
    /// 全モデルが使える状態か（検索モデルの初回最適化は含めない。それはバックグラウンドで続き、メニューバーに出す）。
    func isPrepared() async -> Bool
    /// 準備を始めて進捗を流す。終わると `.finished` を流して閉じる。失敗は throw。
    func prepare() -> AsyncThrowingStream<ModelPreparationProgress, Error>
}
