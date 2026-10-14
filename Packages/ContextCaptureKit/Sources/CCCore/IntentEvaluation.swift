import Foundation

public struct LabeledIntentPrediction: Sendable {
    public let truth: Intent
    public let probabilities: [Intent: Double]
    public init(truth: Intent, probabilities: [Intent: Double]) { self.truth = truth; self.probabilities = probabilities }
}

/// Coverage and accuracy among accepted predictions; abstention is reported separately.
public enum IntentEvaluation {
    public struct Metrics: Codable, Sendable {
        public let threshold: Double
        public let samples: Int
        public let classified: Int
        public let correct: Int
        public let coverage: Double
        public let accuracy: Double?
        public let goldCounts: [String: Int]
        public let confusion: [String: [String: Int]]
    }
    public enum EvaluationError: Error { case invalidThreshold, noLabels, invalidProbabilities }

    public static func evaluate(_ rows: [LabeledIntentPrediction], threshold: Double) throws -> Metrics {
        guard threshold.isFinite, (0...1).contains(threshold) else { throw EvaluationError.invalidThreshold }
        guard !rows.isEmpty else { throw EvaluationError.noLabels }
        var classified = 0, correct = 0, gold: [String: Int] = [:], confusion: [String: [String: Int]] = [:]
        for row in rows {
            guard Set(row.probabilities.keys) == Set(Intent.allCases),
                  row.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(row.probabilities.values.reduce(0, +) - 1) <= 0.001 else { throw EvaluationError.invalidProbabilities }
            let prediction = resolveIntent(probabilities: row.probabilities, threshold: threshold).intent
            gold[row.truth.rawValue, default: 0] += 1
            confusion[row.truth.rawValue, default: [:]][prediction?.rawValue ?? "unclassified", default: 0] += 1
            if let prediction { classified += 1; if prediction == row.truth { correct += 1 } }
        }
        return Metrics(threshold: threshold, samples: rows.count, classified: classified, correct: correct,
                       coverage: Double(classified) / Double(rows.count), accuracy: classified == 0 ? nil : Double(correct) / Double(classified),
                       goldCounts: gold, confusion: confusion)
    }
}
