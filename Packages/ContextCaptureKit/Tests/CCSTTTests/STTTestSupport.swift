import AVFoundation
import CCCore
import Darwin
import Foundation
import XCTest
@testable import CCSTT

/// fixtures・モデルの場所と、CER などの採点（`poc/scripts/common.py` と同じ定義）。
enum STTTestSupport {
    /// リポジトリ（またはこの worktree）のルート。このファイルの位置から辿る。
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        // .../Packages/ContextCaptureKit/Tests/CCSTTTests/STTTestSupport.swift → 5 つ上
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static var fixturesDir: URL { repoRoot.appendingPathComponent("poc/fixtures", isDirectory: true) }

    /// 結合テストに使うモデル。探索の規則は `TestModelLocator`（全テストターゲット共通）:
    /// `CC_MODELS_DIR` 指定時はその下だけ（無ければ throw = 失敗）、未指定なら既定の保存先 → スパイクの変換済みモデル（無ければ nil）。
    static func locateModel() throws -> WhisperModelLayout? {
        try TestModelLocator.locate(.whisper) { WhisperModelLayout(root: $0).missingFiles().isEmpty }
            .map { WhisperModelLayout(root: $0) }
    }

    struct Capture: Decodable {
        let id: Int
        let text: String
    }

    static func loadCaptures() throws -> [Capture] {
        struct Dataset: Decodable { let captures: [Capture] }
        let data = try Data(contentsOf: fixturesDir.appendingPathComponent("dataset.json"))
        return try JSONDecoder().decode(Dataset.self, from: data).captures
    }

    static func audioURL(id: Int) -> URL {
        fixturesDir.appendingPathComponent(String(format: "audio/c%02d.wav", id))
    }

    /// 16kHz モノラル WAV を Float で読む。
    static func loadWav(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        precondition(file.fileFormat.sampleRate == 16_000, "fixtures は 16kHz のはず")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    // MARK: - 採点（poc/scripts/common.py と同一定義）

    /// `re.sub(r"[\s、。，．,.!！?？「」『』・:：]", "", s).lower()` と同じ。
    static func normalizeJa(_ s: String) -> [Unicode.Scalar] {
        let removed: Set<Unicode.Scalar> = Set("、。，．,.!！?？「」『』・:：".unicodeScalars)
        let kept = s.unicodeScalars.filter { !$0.properties.isWhitespace && !removed.contains($0) }
        return Array(String(String.UnicodeScalarView(kept)).lowercased().unicodeScalars)
    }

    /// 文字誤り率（編集距離 / 正解の文字数）。
    static func cer(ref: String, hyp: String) -> Double {
        let r = normalizeJa(ref), h = normalizeJa(hyp)
        var d = Array(0...h.count)
        for (i, rc) in r.enumerated() {
            var prev = d[0]
            d[0] = i + 1
            for (j, hc) in h.enumerated() {
                let cur = d[j + 1]
                d[j + 1] = min(d[j + 1] + 1, d[j] + 1, prev + (rc == hc ? 0 : 1))
                prev = cur
            }
        }
        return Double(d[h.count]) / Double(max(1, r.count))
    }

    /// `lat_summary` の分位点（ソート後 `round(q * (n - 1))` 番目）。
    static func percentile(_ xs: [Double], _ q: Double) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return .nan }
        let index = Int((q * Double(s.count - 1)).rounded(.toNearestOrEven))
        return s[min(s.count - 1, index)]
    }

    /// 常駐メモリ（MB）。
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1e6 : -1
    }

    /// PoC（mlx-whisper の initial_prompt）と同じ語彙。fixtures に合わせて足し引きしない（評価を甘くしないため）。
    static let pocVocabulary = ["Hermes", "Claude Code", "OpenDots", "GitHub", "issue", "pytest", "adapter.ts"]
}
