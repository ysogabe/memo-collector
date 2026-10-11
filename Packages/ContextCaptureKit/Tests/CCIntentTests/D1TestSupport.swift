import CCCore
import Foundation
import XCTest
@testable import CCIntent

/// テスト用のファイル探索。CCIntentTests には resources 宣言が無い（Package.swift は Wave 0 の所有）ので、
/// フィクスチャと参照データは `#filePath` から相対で辿る。
enum D1TestSupport {
    /// この Tests/CCIntentTests ディレクトリ。
    static let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    /// リポジトリのルート（Packages/ContextCaptureKit/Tests/CCIntentTests から 4 つ上）。
    static let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let fixturesDir = testsDir.appendingPathComponent("Fixtures")
    /// PyTorch MPS bf16 の参照（dev 30 + holdout 22 件 × 2 質問）。git 管理下。
    static let referenceURL = repoRoot.appendingPathComponent("spikes/runtime/data/d1_reference_mps_bf16.json")
    /// HF 元モデル（revision 051bcc4）の Python キャッシュ。
    static let hfSnapshot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".cache/huggingface/hub/models--LiquidAI--d1-3B/snapshots/051bcc464b01b9f92942b364d9586b0ef5912432")

    /// d1 の tokenizer.json。モデルディレクトリ（`modelDirectory()`）→ `CC_MODELS_DIR` 未指定のときだけ HF キャッシュの順。
    /// `CC_MODELS_DIR` 指定で d1 が無ければ throw（失敗）、未指定でどこにも無ければ nil。
    static func tokenizerJSON() throws -> URL? {
        if let dir = try modelDirectory() { return dir.appendingPathComponent("tokenizer.json") }
        let hf = hfSnapshot.appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: hf.path) ? hf : nil
    }

    static let sharedTokenizer: Result<D1Tokenizer, Error>? = {
        do {
            guard let url = try tokenizerJSON() else { return nil }
            return Result { try D1Tokenizer(tokenizerJSON: url) }
        } catch {
            return .failure(error)
        }
    }()

    static func tokenizer() throws -> D1Tokenizer {
        guard let r = sharedTokenizer else {
            throw XCTSkip("d1 の tokenizer.json が見つからない（CC_MODELS_DIR か HF キャッシュが必要）")
        }
        return try r.get()
    }

    /// モデル（MLX 8bit）のディレクトリ。config.json・safetensors・tokenizer.json が揃っているもの。
    /// 探索の規則は `TestModelLocator`（全テストターゲット共通）: `CC_MODELS_DIR` 指定時はその下だけ（無ければ throw = 失敗）、
    /// 未指定なら既定の保存先（無ければ nil）。
    static func modelDirectory() throws -> URL? {
        try TestModelLocator.locate(.d1) { dir in
            ["config.json", "model.safetensors", "tokenizer.json"].allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
        }
    }

    struct Reference: Decodable {
        struct Q: Decodable {
            let prompt: String
            let ids: [Int]
            let groups: [[Int]]
            let chain_probs: [Double]
            let tree_probs: [Double]
        }
        struct Row: Decodable {
            let id: Int
            let split: String
            let text: String
            let gold_intent: String
            let gold_deadline: Bool?
            let labels: [String]
            let q: [String: Q]
        }
        let rows: [Row]
    }

    static func reference() throws -> Reference {
        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            throw XCTSkip("参照データが無い: \(referenceURL.path)")
        }
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: referenceURL))
    }

    struct Cases: Decodable {
        struct Prompt: Decodable { let prompt: String; let ids: [Int] }
        struct Case: Decodable { let text: String; let ids: [Int]; let prompts: [String: Prompt] }
        let tokenizers_version: String
        let readout_ids: [String: [[Int]]]
        let cases: [Case]
    }

    static func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: fixturesDir.appendingPathComponent("d1_tokenizer_cases.json")))
    }

    static func question(_ name: String) -> D1Question {
        name == "intent" ? D1Questions.intent : D1Questions.deadline
    }
}
