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
    /// `.skipped(.notReady)` はモデルが未準備のため後回しにしたもの（失敗ではない。次回の `resumePending` で拾われる）。
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
    /// 処理中にスクショが差し替わった・消えた（ガード結果は別の画像のものなので書かない）。
    case screenshotChanged
    /// 処理中にレコードが削除された。
    case recordMissing
    /// モデル（d1・埋め込み）が未準備（ファイルが無い・読み込みや初回最適化の途中）。何も書いていないので、
    /// モデルが揃った後の `resumePending()` がこのステップを拾う。判定は `ModelReadinessReporting.isModelNotReady`。
    case notReady
}

extension TriageStepOutcome {
    /// モデルが未準備で後回しにしたか（`.skipped(.notReady)`）。
    public var isDeferredUntilReady: Bool { self == .skipped(.notReady) }
}

/// `TriageQueue.reindexAndWait(ids:)` の結果。
public struct TriageReindexReport: Sendable, Equatable {
    /// 依頼した記録の数（重複は 1 つ）。
    public var requested: Int
    /// 索引ステップが成功しなかった記録（依頼した順）。空なら全件がこの埋め込みで索引された。
    public var failedIDs: [String]

    public init(requested: Int, failedIDs: [String]) {
        self.requested = requested
        self.failedIDs = failedIDs
    }
}

/// UI に流す進捗。
public enum TriageEvent: Sendable, Equatable {
    /// あるレコードのあるステップが終わった。
    case stepFinished(id: String, step: TriageStep, outcome: TriageStepOutcome)
    /// あるレコードの（依頼された）全ステップが終わった。
    case recordFinished(id: String)
    /// キューが空になった。
    case idle
    /// Workerがcapture pauseの境界で待機に入った。
    case suspendedForCapture
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

/// `RecordModifying` / `EmbeddingPresenceChecking` は CCCore へ移した（`SQLiteRecordStore` の準拠は CCStore が宣言する）。
/// 以前 `CCTriage.RecordModifying` のように修飾して書いていたコードのために名前を残す。
public typealias RecordModifying = CCCore.RecordModifying
public typealias EmbeddingPresenceChecking = CCCore.EmbeddingPresenceChecking

/// トリアージが使うストア。
public typealias TriageRecordStore = RecordStore & RecordModifying & EmbeddingPresenceChecking

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
