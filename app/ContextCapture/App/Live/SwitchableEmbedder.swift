import CCCore
import CoreGraphics
import Foundation

/// 準備（読み込み + 初回推論）が要る埋め込み。本物は `CoreMLEmbedder`（適合は `TriageAssembly.swift`）。
protocol PreparableEmbedder: Embedder, ModelUnloadable {
    /// 索引の互換性を表す文字列（`CoreMLEmbedder.Configuration.indexSignature`）。変わったら全件を埋め込み直す。
    var indexSignature: String { get }
    /// 読み込みと最初の推論を済ませる（ANE の初回特殊化で数分かかりうる）。
    func prepareForUse() async throws
    /// デバッグ表示用の読み込み状態（例: "text+vision"）。
    func loadDescription() async -> String
}

/// 埋め込みが準備中・未準備のとき（すぐ throw して、呼び出し側に後回しさせる）。
/// `ModelReadinessReporting` なので、トリアージは失敗ではなく `.skipped(.notReady)` にする（`resumePending()` で拾われる）。
struct EmbeddingNotReady: ModelReadinessReporting, Equatable {
    var isModelNotReady: Bool { true }
}

/// アプリで使う埋め込みの持ち手。`TriageQueue`（索引）と検索の両方がこれを持つ。
///
/// - 中身（`PreparableEmbedder`）は差し替えられる（設定の画像トークン数を変えたとき。`CoreMLEmbedder` の設定は不変なので作り直す）
/// - **準備が終わるまでは `embedQuery` / `embedDocument` がすぐ `EmbeddingNotReady` を投げる**。トリアージの索引ステップは
///   `.skipped(.notReady)`（失敗ではない）で残り、準備後の `resumePending()` で拾われる（直列キューが数分の初回特殊化で止まらないように）
actor SwitchableEmbedder: Embedder {
    enum State: Sendable, Equatable {
        case unavailable
        case preparing
        case ready
        case failed(String)
    }

    nonisolated let dimension: Int
    private var current: (any PreparableEmbedder)?
    private(set) var state: State = .unavailable
    private var generation = 0

    init(dimension: Int = 256) {
        self.dimension = dimension
    }

    var isReady: Bool { state == .ready }
    /// 今の中身の索引シグネチャ（中身が無ければ nil）。
    var indexSignature: String? { current?.indexSignature }

    /// 中身を差し替えて準備する。準備が終わる（または失敗する）と返る。古い中身は解放する。
    /// 準備中にさらに差し替えられたら、古い準備の結果は捨てる（返り値は呼んだ時点の世代のものではなく現在の状態）。
    @discardableResult
    func install(_ embedder: any PreparableEmbedder) async -> State {
        generation += 1
        let gen = generation
        let old = current
        current = embedder
        state = .preparing
        if let old { await old.unload() }
        do {
            try await embedder.prepareForUse()
            if gen == generation { state = .ready }
        } catch {
            if gen == generation { state = .failed(String(describing: type(of: error))) }
            CCLog.models.error("embedder prepare failed: \(String(describing: error), privacy: .public)")
        }
        return state
    }

    /// 中身を外す（モデルが消えたときなど）。
    func uninstall() async {
        generation += 1
        let old = current
        current = nil
        state = .unavailable
        if let old { await old.unload() }
    }

    func loadDescription() async -> String {
        guard let current else { return "なし" }
        return await current.loadDescription()
    }

    // MARK: - Embedder

    func embedQuery(_ text: String) async throws -> [Float] {
        guard state == .ready, let current else { throw EmbeddingNotReady() }
        return try await current.embedQuery(text)
    }

    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] {
        guard state == .ready, let current else { throw EmbeddingNotReady() }
        return try await current.embedDocument(text: text, title: title, image: image)
    }
}
