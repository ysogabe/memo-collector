import CCCore
import CCEmbedding
import CCTriage
import Foundation

// CCTriage / CCEmbedding の本物をアプリのプロトコル（`TriageQueuing` / `PreparableEmbedder`）へ合わせる薄い適合。

extension TriageQueue: TriageQueuing {
    func annotationEdited(id: String) async {
        reprocess(id: id)
    }

    func reindex(id: String) async {
        reprocess(id: id, steps: [.index])
    }

    func reindexAll(ids: [String]) async -> [String] {
        await reindexAndWait(ids: ids).failedIDs
    }

    func setCapturing(_ capturing: Bool) async {
        if capturing { pause() } else { resume() }
    }
}

extension CoreMLEmbedder: PreparableEmbedder {
    nonisolated var indexSignature: String { configuration.indexSignature }

    func prepareForUse() async throws {
        let report = try await prepare(includeVision: true)
        CCLog.models.notice("""
            embedder prepared: text \(report.textLoadSeconds, format: .fixed(precision: 1), privacy: .public)s \
            vision \(report.visionLoadSeconds, format: .fixed(precision: 1), privacy: .public)s \
            first \(report.firstInferenceSeconds, format: .fixed(precision: 2), privacy: .public)s
            """)
    }

    func loadDescription() async -> String {
        switch (isLoaded, isVisionLoaded) {
        case (true, true): return "テキスト+画像"
        case (true, false): return "テキストのみ"
        case (false, true): return "画像のみ"
        case (false, false): return "未読み込み"
        }
    }
}

extension CoreMLEmbedder.Configuration {
    /// アプリの設定の画像トークン数（70 / 140 / 280）から作る。知らない値は既定の 280。
    static func app(modelDirectory: URL, imageTokens: Int) -> CoreMLEmbedder.Configuration {
        CoreMLEmbedder.Configuration(
            modelDirectory: modelDirectory,
            imageTokens: ImageTokenBudget(rawValue: imageTokens) ?? .tokens280,
            textComputeUnits: .cpuAndNeuralEngine,
            visionComputeUnits: .cpuAndNeuralEngine
        )
    }
}
