import CCCore
import CCStore
import CoreGraphics
import Foundation
import ImageIO

// MARK: - ステップとイベント

/// トリアージの 1 段。順序は guard → intent → index。
public enum TriageStep: String, Sendable, CaseIterable, Hashable, Comparable {
    /// 秘密情報ガード（OCR + 正規表現）。
    case guardScan = "guard"
    /// 意図・日時言及（d1）。
    case intent
    /// 検索インデックス（埋め込み）。
    case index

    public static func < (a: TriageStep, b: TriageStep) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// ステップ 1 つの結果。
public enum TriageStepOutcome: Sendable, Equatable {
    /// 書き込んだ。
    case succeeded
    /// 何もしなかった（理由つき。例: 注釈が空、手動で変更済み、処理中に注釈が編集された）。
    case skipped(TriageSkipReason)
    /// 失敗した（次回の `resumePending` か `reprocess` で再試行される）。説明は型名程度で、秘密や本文は含まない。
    case failed(String)
}

public enum TriageSkipReason: String, Sendable, Equatable {
    /// 注釈が空（前処理後）。
    case emptyAnnotation
    /// ユーザーが手で意図を変えている（`TriageResult.model == TriageMarkers.manualModel`）。
    case manuallyEdited
    /// 推定中に注釈が編集された（編集側が `reprocess` を投げるので、古い結果は書かない）。
    case annotationChanged
    /// ガードが既に pending ではない（ユーザーが clear / masked にした等）。
    case alreadyReviewed
    /// 処理中にレコードが削除された。
    case recordMissing
}

/// UI に流す進捗。
public enum TriageEvent: Sendable, Equatable {
    /// あるレコードのあるステップが終わった。
    case stepFinished(id: String, step: TriageStep, outcome: TriageStepOutcome)
    /// あるレコードの（依頼された）全ステップが終わった。
    case recordFinished(id: String)
    /// キューが空になった。
    case idle
    /// 無使用時間が過ぎて意図モデル（d1）を解放した。
    case classifierUnloaded
}

// MARK: - 手動変更の目印

public enum TriageMarkers {
    /// ユーザーが Inbox で意図を手で変えたときに `TriageResult.model` へ入れる値。
    /// **UI との契約**: これが入っている triage はトリアージ（自動推定）が上書きしない。
    public static let manualModel = "user"
}

extension TriageResult {
    /// ユーザーの手動変更を表す TriageResult（UI が意図を変えたときに使う）。確信度は 1。
    public static func manual(intent: Intent?, mentionsDatetime: Bool) -> TriageResult {
        TriageResult(intent: intent, intentConfidence: 1, mentionsDatetime: mentionsDatetime, model: TriageMarkers.manualModel)
    }

    /// ユーザーが手で変えたものか。
    public var isManual: Bool { model == TriageMarkers.manualModel }
}

// MARK: - ストアへの追加要求

/// トランザクション内の read-modify-write（`SQLiteRecordStore.modify`）。
/// CCCore の `RecordStore` に無いので CCTriage 側で宣言し、`SQLiteRecordStore` を適合させる
/// （CCCore へ移すことを提案済み）。
public protocol RecordModifying: Sendable {
    @discardableResult
    func modify(id: String, _ transform: @escaping @Sendable (inout ContextRecord) throws -> Void) async throws -> ContextRecord
}

/// 埋め込みを持つレコード id の集合。CCStore に専用 API が無いので、既定実装は
/// 「零ベクトルで全件検索すると埋め込みのあるレコードが全部返る」ことを使う（O(N)、起動時に 1 回だけ）。
public protocol EmbeddingPresenceChecking: Sendable {
    func idsWithEmbedding(dimension: Int) async throws -> Set<String>
}

extension EmbeddingPresenceChecking where Self: RecordStore {
    public func idsWithEmbedding(dimension: Int) async throws -> Set<String> {
        let total = try await count(InboxFilter(statuses: []))
        guard total > 0 else { return [] }
        let hits = try await search(vector: [Float](repeating: 0, count: dimension), limit: total)
        return Set(hits.map(\.record.id))
    }
}

/// トリアージが使うストア。
public typealias TriageRecordStore = RecordStore & RecordModifying & EmbeddingPresenceChecking

extension SQLiteRecordStore: RecordModifying, EmbeddingPresenceChecking {}

// MARK: - 画像の読み込み

/// スクショ（データルートからの相対パス）を CGImage にする。
public protocol ScreenshotLoading: Sendable {
    func loadScreenshot(relativePath: String) async throws -> CGImage
}

public enum ScreenshotLoadError: Error, Equatable {
    case notFound
    case undecodable
}

/// `RecordStore.attachmentURL` でパスを解決して ImageIO で読む。
public struct StoreScreenshotLoader: ScreenshotLoading {
    public let store: any RecordStore

    public init(store: any RecordStore) {
        self.store = store
    }

    public func loadScreenshot(relativePath: String) async throws -> CGImage {
        let url = try await store.attachmentURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ScreenshotLoadError.notFound }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ScreenshotLoadError.undecodable }
        return image
    }
}
