import Foundation
import Observation
import os

/// ログと signpost のサブシステム（Console.app / Instruments で `dev.ysogabe.ContextCapture` を絞り込む）。
enum CCLog {
    static let subsystem = "dev.ysogabe.ContextCapture"
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let hotKey = Logger(subsystem: subsystem, category: "hotkey")
    static let models = Logger(subsystem: subsystem, category: "models")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let triage = Logger(subsystem: subsystem, category: "triage")
    /// Instruments の「os_signpost」で区間を見る（押下→録音開始、解放→保存）。
    static let signposter = OSSignposter(subsystem: subsystem, category: "latency")
}

/// 直近 N 件の測定値（ミリ秒）と p50 / p90（PRD §10 の確認用。デバッグメニューに出す）。
struct LatencySamples: Equatable, Sendable {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int = 20) {
        self.capacity = capacity
    }

    mutating func append(_ ms: Double) {
        values.append(ms)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    var count: Int { values.count }

    /// 最近傍順位法（n 件を並べて ceil(p·n) 番目）。0 件なら nil。
    func percentile(_ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    var p50: Double? { percentile(0.5) }
    var p90: Double? { percentile(0.9) }

    /// 「p50 120ms / p90 140ms（n=20）」。
    var summary: String {
        guard let p50, let p90 else { return "まだ測っていません" }
        return String(format: "p50 %.0fms / p90 %.0fms（n=%d）", p50, p90, count)
    }
}

/// 押下→録音開始・解放→保存の計測（AppCoordinator が書き、デバッグメニューが読む）。
@Observable
@MainActor
final class CaptureLatencyMonitor {
    enum Metric: String, CaseIterable, Sendable {
        /// ホットキー押下（OS のイベント時刻）→ `recorder.start()` の完了。目標 ≤ 150ms。
        case pressToRecording
        /// ホットキー解放（OS のイベント時刻）→ `.saved` を流す直前。目標 p90 ≤ 2000ms。
        case releaseToSaved

        var title: String {
            switch self {
            case .pressToRecording: return "押下→録音開始"
            case .releaseToSaved: return "解放→保存"
            }
        }
    }

    private(set) var samples: [Metric: LatencySamples] = [:]

    func record(_ metric: Metric, milliseconds ms: Double) {
        var s = samples[metric] ?? LatencySamples()
        s.append(ms)
        samples[metric] = s
        CCLog.capture.info("latency \(metric.rawValue, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public)ms")
    }

    func summary(_ metric: Metric) -> String {
        (samples[metric] ?? LatencySamples()).summary
    }

    /// コピー用のテキスト（値の一覧つき）。
    var report: String {
        Metric.allCases.map { m in
            let s = samples[m] ?? LatencySamples()
            let values = s.values.map { String(format: "%.0f", $0) }.joined(separator: ", ")
            return "\(m.title): \(s.summary)\n  [\(values)]"
        }.joined(separator: "\n")
    }
}
