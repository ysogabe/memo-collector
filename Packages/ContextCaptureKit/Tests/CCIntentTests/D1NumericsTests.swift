import CCCore
import Foundation
import MLX
import XCTest
@testable import CCIntent

/// MLX 8bit の d1 と PyTorch MPS bf16 参照（spikes/runtime/data/d1_reference_mps_bf16.json）の数値比較。
/// モデル（CC_MODELS_DIR/d1-3b-text-q8）が無ければ skip。トークン列は **Swift の D1Tokenizer で作ったもの**を使う。
/// 結果の要約は標準出力の `D1NUMERICS ` 行に JSON で出し、環境変数 `CC_D1_RESULTS_OUT` があればそのパスにも書く。
final class D1NumericsTests: XCTestCase {
    static let labels = Intent.allCases.map(\.rawValue)

    func testReferenceParityAccuracyLatencyAndUnload() async throws {
        guard let dir = D1TestSupport.modelDirectory() else {
            throw XCTSkip("d1 モデルが無い（CC_MODELS_DIR/\(ModelSlot.d1.directoryName)）")
        }
        let ref = try D1TestSupport.reference()
        let clf = D1IntentClassifier(modelDirectory: dir)
        let loadedBefore = await clf.isLoaded
        XCTAssertFalse(loadedBefore)
        let load = try await clf.load()
        let loadedAfter = await clf.isLoaded
        XCTAssertTrue(loadedAfter)

        let tok = try D1Tokenizer(tokenizerJSON: dir.appendingPathComponent("tokenizer.json"))
        let prompt = D1Prompt(tokenizer: tok)

        var maxIntent = 0.0, maxDeadline = 0.0, maxIntentTree = 0.0
        var top1Chain = 0, top1Tree = 0, deadlineTop1 = 0
        var correct: [String: Int] = ["dev": 0, "holdout": 0], total: [String: Int] = ["dev": 0, "holdout": 0]
        var tokenMismatch = 0
        var rowsOut: [[String: Any]] = []
        for row in ref.rows {
            let iq = row.q["intent"]!, dq = row.q["deadline"]!
            let iIds = try prompt.encode(state: row.text, question: D1Questions.intent)
            let dIds = try prompt.encode(state: row.text, question: D1Questions.deadline)
            if iIds != iq.ids || dIds != dq.ids { tokenMismatch += 1 }
            let p = try await clf.probabilities(text: row.text)
            let pd = [p.datetime, 1 - p.datetime]
            maxIntent = max(maxIntent, zip(p.intent, iq.chain_probs).map { abs($0 - $1) }.max()!)
            maxIntentTree = max(maxIntentTree, zip(p.intent, iq.tree_probs).map { abs($0 - $1) }.max()!)
            maxDeadline = max(maxDeadline, zip(pd, dq.chain_probs).map { abs($0 - $1) }.max()!)
            if argmax(p.intent) == argmax(iq.chain_probs) { top1Chain += 1 }
            if argmax(p.intent) == argmax(iq.tree_probs) { top1Tree += 1 }
            if argmax(pd) == argmax(dq.chain_probs) { deadlineTop1 += 1 }
            total[row.split, default: 0] += 1
            if Self.labels[argmax(p.intent)] == row.gold_intent { correct[row.split, default: 0] += 1 }
            rowsOut.append(["id": row.id, "intent": p.intent, "datetime": p.datetime])
        }
        XCTAssertEqual(tokenMismatch, 0)
        XCTAssertLessThanOrEqual(maxIntent, 0.05, "intent max |Δp| vs PyTorch chain")
        XCTAssertLessThanOrEqual(maxDeadline, 0.05, "datetime max |Δp| vs PyTorch chain")
        XCTAssertGreaterThanOrEqual(correct["holdout"]!, 20, "holdout accuracy")
        XCTAssertGreaterThanOrEqual(correct["dev"]!, 24, "dev accuracy")
        XCTAssertEqual(total["dev"], 30)
        XCTAssertEqual(total["holdout"], 22)

        // classify() は probabilities と同じ値で TriageResult を作る
        let r = try await clf.classify(text: ref.rows[0].text)
        XCTAssertEqual(r.model, D1IntentClassifier.defaultModelIdentifier)
        XCTAssertEqual(r.intentProbabilities?.count, 5)

        // ---- レイテンシ: 1 件 = 2 質問（トークン化込み）。3 周、各周の p50 / p90。
        let iso = ISO8601DateFormatter()
        let startedAt = iso.string(from: Date())
        var reps: [[String: Double]] = []
        for _ in 0..<3 {
            var lats: [Double] = []
            for row in ref.rows {
                let t = Date()
                _ = try await clf.probabilities(text: row.text)
                lats.append(Date().timeIntervalSince(t))
            }
            lats.sort()
            reps.append(["p50_s": lats[lats.count / 2], "p90_s": lats[Int(0.9 * Double(lats.count - 1))]])
        }
        let finishedAt = iso.string(from: Date())
        let p50 = reps.map { $0["p50_s"]! }.sorted()[1]
        let p90 = reps.map { $0["p90_s"]! }.sorted()[1]
        XCTAssertLessThanOrEqual(p50, 1.5, "latency p50 (2 questions)")
        let rssLoaded = D1IntentClassifier.residentBytes()
        let mlxActiveLoaded = Memory.activeMemory

        await clf.unload()
        let loadedAfterUnload = await clf.isLoaded
        XCTAssertFalse(loadedAfterUnload)
        let mlxActiveAfterUnload = Memory.activeMemory
        XCTAssertLessThan(mlxActiveAfterUnload, mlxActiveLoaded / 4, "unload で MLX のメモリが返る")

        let summary: [String: Any] = [
            "model_dir": dir.path,
            "token_mismatch_rows": tokenMismatch,
            "intent_max_abs_dp_vs_chain": maxIntent, "intent_max_abs_dp_vs_tree": maxIntentTree,
            "datetime_max_abs_dp_vs_chain": maxDeadline,
            "intent_top1_agree_chain": "\(top1Chain)/52", "intent_top1_agree_tree": "\(top1Tree)/52",
            "datetime_top1_agree_chain": "\(deadlineTop1)/52",
            "accuracy_dev": "\(correct["dev"]!)/30", "accuracy_holdout": "\(correct["holdout"]!)/22",
            "latency": ["started_at": startedAt, "finished_at": finishedAt, "reps": reps,
                        "p50_median_of_reps_s": p50, "p90_median_of_reps_s": p90],
            "load_s": load.loadSeconds, "tokenizer_load_s": load.tokenizerSeconds,
            "mlx_active_after_load_mb": Double(load.mlxActiveBytes) / 1e6,
            "mlx_peak_mb": Double(Memory.peakMemory) / 1e6,
            "rss_before_load_mb": Double(load.residentBytesBefore) / 1e6,
            "rss_after_load_mb": Double(load.residentBytesAfter) / 1e6,
            "rss_after_bench_mb": Double(rssLoaded) / 1e6,
            "mlx_active_after_unload_mb": Double(mlxActiveAfterUnload) / 1e6,
            "rss_after_unload_mb": Double(D1IntentClassifier.residentBytes()) / 1e6,
            "rows": rowsOut,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        if let out = ProcessInfo.processInfo.environment["CC_D1_RESULTS_OUT"], !out.isEmpty {
            try data.write(to: URL(fileURLWithPath: out))
        }
        var brief = summary
        brief["rows"] = nil
        print("D1NUMERICS " + String(data: try JSONSerialization.data(withJSONObject: brief, options: [.sortedKeys]), encoding: .utf8)!)
    }

    private func argmax(_ p: [Double]) -> Int { p.indices.max { p[$0] < p[$1] }! }
}
