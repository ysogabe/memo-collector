import ArgumentParser
import CCCore
import CCIntent
import CCModels
import CCStore
import CCTriage
import CryptoKit
import Foundation

struct EvaluateIntentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "eval-intent", abstract: "手動正解ラベルで意図の質問文・しきい値を比較する（DB は読み取り専用）")
    @Option(help: "既存 SQLite。省略時は既定 DB。入力 JSON と併用不可") var database: String?
    @Option(help: "kind (manual/synthetic) と samples (id, text, truth, probabilities?) を持つ JSON") var input: String?
    @Option(help: "比較する質問文 JSON。指定すると既存モデルで再推論する") var candidate: [String] = []
    @Flag(help: "製品の質問文でも再推論する。省略時は保存済み確率のみ") var recompute = false
    @Flag(help: "coverage / accuracy を Markdown 表で表示する。--output の JSON 保存と併用可") var table = false
    @Flag(help: "製品の質問文 JSON を標準出力に表示して終了") var printQuestion = false
    @Option(help: "カンマ区切りのしきい値") var thresholds = "0.5,0.6,0.7,0.8,0.9"
    @Option(help: "集計 JSON の保存先。注釈・ID は出力しない") var output: String?

    private struct Input: Decodable {
        struct Sample: Decodable { let id: String; let text: String; let truth: Intent; let probabilities: [Intent: Double]? }
        let kind: String
        let samples: [Sample]
    }
    private struct Evaluation: Encodable {
        let name: String
        let probabilitySource: String
        let questionSHA256: String?
        let evaluated: Int
        let missingStoredProbabilities: Int
        let development: [IntentEvaluation.Metrics]
        let holdout: [IntentEvaluation.Metrics]
    }
    private struct Report: Encodable {
        let schemaVersion = 1
        let datasetKind: String
        let totalRecords: Int
        let labeledRecords: Int
        let labelCountSufficient: Bool
        let split: String
        let preprocessingMaxCharacters: Int
        let modelIdentifier: String?
        let modelConfigSHA256: String?
        let modelWeightsSHA256: String?
        let evaluations: [Evaluation]
        let status: String
    }

    mutating func run() async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if printQuestion { print(String(decoding: try encoder.encode(IntentQuestionCandidate.product), as: UTF8.self)); return }
        guard database == nil || input == nil else { throw ValidationError("--database と --input は併用できません") }
        let cutoffs = try thresholds.split(separator: ",", omittingEmptySubsequences: false).map { value -> Double in
            guard let t = Double(value), t.isFinite, (0...1).contains(t) else { throw ValidationError("しきい値は 0〜1 の有限値") }
            return t
        }
        guard !cutoffs.isEmpty else { throw ValidationError("しきい値が必要です") }
        let samples: [ManualIntentSample], total: Int, kind: String
        if let input {
            let parsed = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
            guard ["manual", "synthetic"].contains(parsed.kind), Set(parsed.samples.map(\.id)).count == parsed.samples.count,
                  parsed.samples.allSatisfy({ !AnnotationPreprocessor.prepare($0.text).isEmpty }) else {
                throw ValidationError("kind は manual/synthetic、ID は一意、注釈は空欄不可")
            }
            samples = parsed.samples.map { ManualIntentSample(id: $0.id, text: $0.text, truth: $0.truth, storedProbabilities: $0.probabilities) }
            total = samples.count; kind = parsed.kind
        } else {
            let data = try ReadOnlyIntentDataset.load(databaseURL: database.map { URL(fileURLWithPath: $0) } ?? CCPaths.resolve().databaseURL)
            samples = data.samples; total = data.totalRecords; kind = "manual-db"
        }
        var questions: [IntentQuestionCandidate] = []
        if recompute || !candidate.isEmpty { questions.append(.product) }
        for path in candidate {
            let q = try JSONDecoder().decode(IntentQuestionCandidate.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            _ = try q.validatedQuestion(); questions.append(q)
        }
        guard Set(questions.map(\.name)).count == questions.count else { throw ValidationError("質問文の name は一意（product は予約名）") }
        // Last 20% is held out before filtering missing probabilities. No threshold is selected automatically.
        let splitAt = samples.count < 5 ? samples.count : samples.count - max(1, samples.count / 5)
        func metrics(_ indexed: [(Int, LabeledIntentPrediction)], development: Bool) throws -> [IntentEvaluation.Metrics] {
            let rows = indexed.filter { development ? $0.0 < splitAt : $0.0 >= splitAt }.map(\.1)
            return rows.isEmpty ? [] : try cutoffs.map { try IntentEvaluation.evaluate(rows, threshold: $0) }
        }
        var evaluations: [Evaluation] = []
        let stored = samples.enumerated().compactMap { i, sample -> (Int, LabeledIntentPrediction)? in
            sample.storedProbabilities.map { (i, LabeledIntentPrediction(truth: sample.truth, probabilities: $0)) }
        }
        evaluations.append(Evaluation(name: "stored", probabilitySource: "stored; original question/model provenance may be unknown",
                                      questionSHA256: nil, evaluated: stored.count, missingStoredProbabilities: samples.count - stored.count,
                                      development: try metrics(stored, development: true), holdout: try metrics(stored, development: false)))
        let paths = CCPaths.resolve()
        let classifier = D1IntentClassifier(modelDirectory: paths.modelDirectory(.d1))
        var modelHash: String?
        var weightsHash: String?
        if !questions.isEmpty && !samples.isEmpty {
            modelHash = try D1ModelPreparer.sha256(of: paths.modelDirectory(.d1).appendingPathComponent("config.json"))
            weightsHash = try D1ModelPreparer.sha256(of: paths.modelDirectory(.d1).appendingPathComponent("model.safetensors"))
            for q in questions {
                var rows: [(Int, LabeledIntentPrediction)] = []
                for (i, sample) in samples.enumerated() {
                    let probabilities = try await classifier.intentProbabilities(text: AnnotationPreprocessor.prepare(sample.text), candidate: q)
                    rows.append((i, LabeledIntentPrediction(truth: sample.truth, probabilities: probabilities)))
                }
                let questionData = try encoder.encode(q)
                let hash = SHA256.hash(data: questionData).map { String(format: "%02x", $0) }.joined()
                evaluations.append(Evaluation(name: q.name, probabilitySource: "recomputed", questionSHA256: hash,
                                              evaluated: rows.count, missingStoredProbabilities: 0,
                                              development: try metrics(rows, development: true), holdout: try metrics(rows, development: false)))
            }
            await classifier.unload()
        }
        let report = Report(datasetKind: kind, totalRecords: total, labeledRecords: samples.count,
                            labelCountSufficient: kind != "synthetic" && samples.count >= 30,
                            split: "input order: first 80% development, last 20% holdout; DB order captured_at/id; fewer than 5: development only",
                            preprocessingMaxCharacters: AnnotationPreprocessor.maxCharacters,
                            modelIdentifier: modelHash == nil ? nil : D1IntentClassifier.defaultModelIdentifier, modelConfigSHA256: modelHash, modelWeightsSHA256: weightsHash,
                            evaluations: evaluations, status: samples.isEmpty ? "needs_manual_labels" : "evaluation_only; adoption/reprocessing requires reviewed evidence")
        let data = try encoder.encode(report)
        if let output {
            let destination = URL(fileURLWithPath: output).standardizedFileURL
            let db = database.map { URL(fileURLWithPath: $0) } ?? paths.databaseURL
            let protectedRoots = [paths.dataRoot, paths.modelsRoot, CCPaths.resolve(environment: [:]).dataRoot, CCPaths.resolve(environment: [:]).modelsRoot]
            guard !protectedRoots.contains(where: { destination.resolvingSymlinksInPath().path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }) else { throw ValidationError("アプリのデータ・モデル領域へレポートを書き込めません") }
            let protected = [db, paths.databaseURL, CCPaths.resolve(environment: [:]).databaseURL] + [input].compactMap { $0 }.map { URL(fileURLWithPath: $0) } + candidate.map { URL(fileURLWithPath: $0) }
            guard !protected.contains(where: { $0.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }) else { throw ValidationError("出力で DB・入力を上書きできません") }
            try data.write(to: destination, options: .atomic)
        } else if !table { print(String(decoding: data, as: UTF8.self)) }
        if table {
            print("labels: \(samples.count) / records: \(total); kind: \(kind); status: \(report.status)")
            print("\n| question | split | threshold | samples | coverage | accuracy (classified) |")
            print("|---|---|---:|---:|---:|---:|")
            for evaluation in evaluations {
                for (name, values) in [("development", evaluation.development), ("holdout", evaluation.holdout)] {
                    for value in values {
                        let accuracy = value.accuracy.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
                        print("| \(evaluation.name.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "\n", with: " ")) | \(name) | \(value.threshold) | \(value.samples) | \(String(format: "%.1f%%", value.coverage * 100)) | \(accuracy) |")
                    }
                }
            }
        }
        if samples.isEmpty { throw ExitCode(2) }
    }
}
