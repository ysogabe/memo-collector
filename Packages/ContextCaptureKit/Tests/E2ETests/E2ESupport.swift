import AVFoundation
import CCCore
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

// Wave 4 e2e の補助（fixtures・メモリ・時間・統計・スクショ符号化）。
// テストターゲット同士は import できないので、他のテストの補助と同じものをここに写してある（定義は各コメントの元と同じ）。

// MARK: - 場所

enum E2EPaths {
    /// リポジトリ（またはこの worktree）のルート。Tests/E2ETests/ → ContextCaptureKit → Packages → ルート。
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static var fixturesDir: URL { repoRoot.appendingPathComponent("poc/fixtures", isDirectory: true) }
    static var d1ReferenceURL: URL { repoRoot.appendingPathComponent("spikes/runtime/data/d1_reference_mps_bf16.json") }
    static var resultsDir: URL { repoRoot.appendingPathComponent("docs/e2e/results", isDirectory: true) }

    static func audioURL(captureID: Int) -> URL {
        fixturesDir.appendingPathComponent(String(format: "audio/c%02d.wav", captureID))
    }

    static func screenURL(_ screenID: String) -> URL {
        fixturesDir.appendingPathComponent("screens/\(screenID).png")
    }
}

// MARK: - 評価データ（poc/fixtures/dataset.json）

struct E2EDataset: Decodable {
    struct Screen: Decodable {
        let id: String
        let app: String
        let window_title: String
        let url: String?
        let context_type: String?
        let contains_secret: Bool
    }

    struct Capture: Decodable {
        let id: Int
        let screen: String
        let text: String
        let intent: String
        let has_deadline: Bool
    }

    struct Query<ID: Decodable & Hashable>: Decodable {
        let q: String
        let relevant: [ID]
    }

    let screens: [Screen]
    let captures: [Capture]
    let text_queries: [Query<Int>]
    let image_queries: [Query<String>]

    static func load() throws -> E2EDataset {
        try JSONDecoder().decode(E2EDataset.self, from: Data(contentsOf: E2EPaths.fixturesDir.appendingPathComponent("dataset.json")))
    }
}

/// d1 の PyTorch MPS bf16 参照（`Tests/CCIntentTests/D1TestSupport.Reference` と同じ形）。
struct D1Reference: Decodable {
    struct Q: Decodable {
        let ids: [Int]
        let chain_probs: [Double]
        let tree_probs: [Double]
    }

    struct Row: Decodable {
        let id: Int
        let split: String
        let text: String
        let gold_intent: String
        let q: [String: Q]
    }

    let rows: [Row]

    static func load() throws -> D1Reference {
        try JSONDecoder().decode(D1Reference.self, from: Data(contentsOf: E2EPaths.d1ReferenceURL))
    }
}

// MARK: - 音声・画像

enum E2EMedia {
    /// 16kHz モノラル WAV を Float で読む（`STTTestSupport.loadWav` と同じ）。
    static func loadWav(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        precondition(file.fileFormat.sampleRate == 16_000, "fixtures は 16kHz のはず")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot read \(url.path)"]) }
        return img
    }
}

/// アプリの `ScreenshotEncoder`（app/ContextCapture/App/Live/ScreenshotEncoder.swift）と同じ規則:
/// ImageIO が書ける形式を WebP → HEIC → PNG の順に選び、非可逆は品質 0.85。
enum E2EScreenshotEncoder {
    struct Format: Sendable, Equatable {
        var type: UTType
        var fileExtension: String
    }

    static let preferred: [Format] = [
        Format(type: .webP, fileExtension: "webp"),
        Format(type: .heic, fileExtension: "heic"),
        Format(type: .png, fileExtension: "png"),
    ]
    static let quality: Double = 0.85

    static let writableFormats: [Format] = {
        let ids = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return preferred.filter { ids.contains($0.type.identifier) }
    }()

    static func encode(_ image: CGImage) -> (data: Data, fileExtension: String)? {
        for f in writableFormats {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, f.type.identifier as CFString, 1, nil) else { continue }
            var props: [CFString: Any] = [:]
            if f.type != .png { props[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            if CGImageDestinationFinalize(dest) { return (out as Data, f.fileExtension) }
        }
        return nil
    }
}

// MARK: - 時間・統計

@inline(__always) func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

enum Stats {
    /// `poc/scripts/common.py` の `lat_summary` と同じ分位点（ソート後 `round(q * (n - 1))` 番目）。
    static func percentile(_ xs: [Double], _ q: Double) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        let index = Int((q * Double(s.count - 1)).rounded(.toNearestOrEven))
        return s[min(s.count - 1, index)]
    }

    static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func summary(_ xs: [Double]) -> [String: Any] {
        var d: [String: Any] = ["n": xs.count]
        if let v = percentile(xs, 0.5) { d["p50"] = v }
        if let v = percentile(xs, 0.9) { d["p90"] = v }
        if let v = xs.max() { d["max"] = v }
        if let v = xs.min() { d["min"] = v }
        if !xs.isEmpty { d["mean"] = xs.reduce(0, +) / Double(xs.count) }
        return d
    }

    /// 周ごとの値の配列（各周 n 件）から、周ごとの中央値・p90 と全体の p50/p90 を作る。
    static func rounds(_ perRound: [[Double]]) -> [String: Any] {
        let all = perRound.flatMap { $0 }
        return [
            "per_round_median": perRound.compactMap { median($0) },
            "per_round_p90": perRound.compactMap { percentile($0, 0.9) },
            "overall": summary(all),
        ]
    }
}

// MARK: - CER（poc/scripts/common.py と同じ定義。STTTestSupport から写した）

enum CER {
    static func normalizeJa(_ s: String) -> [Unicode.Scalar] {
        let removed: Set<Unicode.Scalar> = Set("、。，．,.!！?？「」『』・:：".unicodeScalars)
        let kept = s.unicodeScalars.filter { !$0.properties.isWhitespace && !removed.contains($0) }
        return Array(String(String.UnicodeScalarView(kept)).lowercased().unicodeScalars)
    }

    /// (編集距離, 正解の文字数)。
    static func distance(ref: String, hyp: String) -> (Int, Int) {
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
        return (d[h.count], r.count)
    }
}

// MARK: - メモリ

/// その時点のメモリ。`phys_footprint`（TASK_VM_INFO。Activity Monitor の「メモリ」と同じ。IOSurface / Metal バッファを含む）が主。
/// RSS は参考（MLX の Metal バッファや Core ML / ANE の領域を反映しない）。
struct MemorySample {
    var footprintMB: Double
    var footprintLifetimePeakMB: Double
    var residentMB: Double
    var mlxActiveMB: Double
    var mlxPeakMB: Double
    var mlxCacheMB: Double

    var json: [String: Any] {
        [
            "phys_footprint_mb": footprintMB, "phys_footprint_lifetime_peak_mb": footprintLifetimePeakMB,
            "rss_mb_reference_only": residentMB, "mlx_active_mb": mlxActiveMB, "mlx_peak_mb": mlxPeakMB, "mlx_cache_mb": mlxCacheMB,
        ]
    }
}

enum ProcessMemory {
    static func footprint() -> (current: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (-1, -1) }
        return (Double(info.phys_footprint) / 1e6, Double(info.ledger_phys_footprint_peak) / 1e6)
    }

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
}

/// 100ms ごとに phys_footprint を見て最大を取る（ledger のピークは生涯値なので区間のピークには使えない）。
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var maxMB = 0.0
    private var maxMLXMB = 0.0
    private var samples = 0
    private var task: Task<Void, Never>?
    private let mlxActive: @Sendable () -> Int

    init(mlxActive: @escaping @Sendable () -> Int) {
        self.mlxActive = mlxActive
    }

    func start() {
        lock.withLock { maxMB = 0; maxMLXMB = 0; samples = 0 }
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func sample() {
        let f = ProcessMemory.footprint().current
        let m = Double(mlxActive()) / 1e6
        lock.withLock {
            maxMB = max(maxMB, f)
            maxMLXMB = max(maxMLXMB, m)
            samples += 1
        }
    }

    func stop() -> [String: Any] {
        task?.cancel()
        task = nil
        sample()
        return lock.withLock { ["max_phys_footprint_mb": maxMB, "max_mlx_active_mb": maxMLXMB, "samples": samples] }
    }
}

// MARK: - 環境

enum E2EEnvironment {
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uptime() -> String { run("/usr/bin/uptime", []) }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        _ = getloadavg(&l, 3)
        return l
    }

    static func machine() -> [String: Any] {
        [
            "cpu": run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
            "model": run("/usr/sbin/sysctl", ["-n", "hw.model"]),
            "memory_gb": (Double(run("/usr/sbin/sysctl", ["-n", "hw.memsize"])) ?? 0) / 1_073_741_824,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }

    /// CPU を使っている上位プロセス（計測を乱すものの記録用）。
    static func topProcesses() -> [String] {
        let out = run("/bin/ps", ["-Ao", "%cpu,rss,comm", "-r"])
        return Array(out.split(separator: "\n").prefix(8).map(String.init))
    }

    static func iso(_ d: Date = Date()) -> String { ISO8601DateFormatter().string(from: d) }
}
