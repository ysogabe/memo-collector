import CCCore
import CoreML
import Foundation

/// Measurement configuration only. The application STT defaults remain unchanged.
struct CaptureReplayConfiguration {
    let encoder: MLComputeUnits
    let decoder: MLComputeUnits
    let encoderName: String
    let decoderName: String
    let quietMilliseconds: Int
    let conditionOrder: [String]

    init(environment: [String: String]) throws {
        func compute(_ key: String) throws -> (MLComputeUnits, String) {
            switch environment[key] ?? "ane" {
            case "ane": return (.cpuAndNeuralEngine, "cpuAndNeuralEngine")
            case "gpu": return (.cpuAndGPU, "cpuAndGPU")
            default: throw NSError(domain: "invalid capture compute option: \(key)", code: 1)
            }
        }
        (encoder, encoderName) = try compute("CC_CAPTURE_STT_ENCODER")
        (decoder, decoderName) = try compute("CC_CAPTURE_STT_DECODER")
        guard let quiet = Int(environment["CC_CAPTURE_QUIET_MS"] ?? "0"), (0...2000).contains(quiet) else {
            throw NSError(domain: "invalid capture quiet milliseconds", code: 1)
        }
        quietMilliseconds = quiet
        conditionOrder = (environment["CC_CAPTURE_CONDITION_ORDER"] ?? "without_triage,with_triage").split(separator: ",").map(String.init)
        guard conditionOrder.count == 2, Set(conditionOrder) == ["without_triage", "with_triage"] else {
            throw NSError(domain: "both capture conditions must occur exactly once", code: 1)
        }
    }
}

enum CaptureReplayMetrics {
    // Same Unicode scalar normalization/edit distance as STTTestSupport and poc/scripts/common.py.
    static func characterErrorRate(reference: String, hypothesis: String) -> Double {
        let removed = Set("、。，．,.!！?？「」『』・:：".unicodeScalars)
        func normalize(_ text: String) -> [Unicode.Scalar] {
            Array(String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isWhitespace && !removed.contains($0) })).lowercased().unicodeScalars)
        }
        let r = normalize(reference), h = normalize(hypothesis)
        var d = Array(0...h.count)
        for (i, rc) in r.enumerated() {
            var previous = d[0]; d[0] = i + 1
            for (j, hc) in h.enumerated() {
                let current = d[j+1]
                d[j+1] = min(d[j+1]+1, d[j]+1, previous + (rc == hc ? 0 : 1))
                previous = current
            }
        }
        return Double(d[h.count]) / Double(max(1, r.count))
    }
}
