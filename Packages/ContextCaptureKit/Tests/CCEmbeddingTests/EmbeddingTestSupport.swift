import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CCCore
@testable import CCEmbedding

/// テストが読むリポジトリ内のファイル（評価データ・参照）とモデルの場所。
enum EmbeddingFixtures {
    /// この worktree のリポジトリルート（Tests/CCEmbeddingTests/ → ContextCaptureKit → Packages → ルート）。
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// git 管理外のもの（スパイクのモデル・`st_inputs.npz`）はメイン作業ツリーにしか無いことがある。
    static let mainRepoRoot: URL? = TestModelLocator.mainWorktreeRoot

    /// `relative` を worktree → メイン作業ツリーの順に探す。
    static func file(_ relative: String) -> URL? {
        for root in [repoRoot, mainRepoRoot].compactMap({ $0 }) {
            let u = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func require(_ relative: String) throws -> URL {
        guard let u = file(relative) else { throw XCTSkip("fixture not found: \(relative)") }
        return u
    }

    /// モデルディレクトリ。探索の規則は `TestModelLocator`（全テストターゲット共通）: `CC_MODELS_DIR` 指定時は
    /// `<dir>/embeddinggemma-2`（`cc-models prepare embedding` の出力）だけ（無ければ throw = 失敗）、未指定なら
    /// 既定の保存先 → スパイクの `spikes/fluid/models/swift-dir`（無ければ nil）。
    static func modelDirectory() throws -> URL? {
        let need = EmbeddingModelFiles.textRequired + EmbeddingModelFiles.visionRequired
        return try TestModelLocator.locate(.embedding) { EmbeddingModelFiles.missing(need, in: $0).isEmpty }
    }

    /// tokenizer.json。モデルディレクトリ →（`CC_MODELS_DIR` 未指定のときだけ）スパイクのスナップショットの順。
    static func tokenizerURL() throws -> URL? {
        if let dir = try modelDirectory() { return dir.appendingPathComponent(EmbeddingModelFiles.tokenizer) }
        return file("spikes/fluid/models/embeddinggemma-2-coreml/tokenizer.json")
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw XCTSkip("cannot read image \(url.path)") }
        return img
    }

    static func screen(_ id: String) throws -> CGImage {
        try loadImage(require("poc/fixtures/screens/\(id).png"))
    }

    /// `spikes/runtime/data/embed_reference.json`（参照に入れた文字列と並び）。
    struct ReferenceMeta: Decodable {
        let doc_texts: [String]
        let text_queries: [String]
        let image_queries: [String]
        let cap_ids: [Int]
        let scr_ids: [String]
        let fused_texts: [String]
        let cap_screens: [String]
    }

    static func referenceMeta() throws -> ReferenceMeta {
        try JSONDecoder().decode(ReferenceMeta.self, from: Data(contentsOf: require("spikes/runtime/data/embed_reference.json")))
    }

    /// `poc/fixtures/dataset.json`。
    struct Dataset: Decodable {
        struct Screen: Decodable {
            let id: String
            let app: String
            let window_title: String
            let url: String?
        }
        struct Capture: Decodable {
            let id: Int
            let screen: String
            let text: String
        }
        struct Query<ID: Decodable & Hashable>: Decodable {
            let q: String
            let relevant: [ID]
        }
        let screens: [Screen]
        let captures: [Capture]
        let text_queries: [Query<Int>]
        let image_queries: [Query<String>]

        /// `poc/scripts/common.py` の `meta_text`。
        func metaText(_ s: Screen) -> String {
            var parts = ["App: \(s.app)", "Window: \(s.window_title)"]
            if let u = s.url, !u.isEmpty { parts.append("URL: \(u)") }
            return parts.joined(separator: "\n")
        }
    }

    static func dataset() throws -> Dataset {
        try JSONDecoder().decode(Dataset.self, from: Data(contentsOf: require("poc/fixtures/dataset.json")))
    }
}

/// `.npz`（numpy の zip）を `/usr/bin/unzip` で展開して `.npy` を読む（float32 / int64 のみ）。
final class NPZ {
    struct Array {
        let shape: [Int]
        let floats: [Float]?
        let ints: [Int64]?

        /// 2 次元以上を行ごとの配列にする（float32）。
        var rows: [[Float]] {
            let f = floats ?? []
            let cols = shape.dropFirst().reduce(1, *)
            return (0..<(shape.first ?? 0)).map { Swift.Array(f[($0 * cols)..<(($0 + 1) * cols)]) }
        }
    }

    private let dir: URL

    init(_ url: URL) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("npz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", url.path, "-d", dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("unzip failed for \(url.path)") }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func array(_ name: String) throws -> Array {
        let data = try Data(contentsOf: dir.appendingPathComponent("\(name).npy"))
        let bytes = [UInt8](data)
        guard bytes.count > 10, bytes[0] == 0x93, String(bytes: bytes[1..<6], encoding: .ascii) == "NUMPY" else {
            throw NSError(domain: "NPZ", code: 1, userInfo: [NSLocalizedDescriptionKey: "not npy: \(name)"])
        }
        let major = bytes[6]
        let headerLen: Int, start: Int
        if major == 1 {
            headerLen = Int(bytes[8]) | Int(bytes[9]) << 8
            start = 10
        } else {
            headerLen = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
            start = 12
        }
        let header = String(bytes: bytes[start..<(start + headerLen)], encoding: .ascii) ?? ""
        let body = data.subdata(in: (start + headerLen)..<data.count)
        let shapeText = header.components(separatedBy: "'shape': (").last?.components(separatedBy: ")").first ?? ""
        let shape = shapeText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard header.contains("'fortran_order': False") else { throw XCTSkip("fortran order npy") }
        if header.contains("'<f4'") {
            let f = body.withUnsafeBytes { Swift.Array($0.bindMemory(to: Float.self)) }
            return Array(shape: shape, floats: f, ints: nil)
        }
        if header.contains("'<i8'") {
            let i = body.withUnsafeBytes { Swift.Array($0.bindMemory(to: Int64.self)) }
            return Array(shape: shape, floats: nil, ints: i)
        }
        throw XCTSkip("unsupported npy dtype: \(header)")
    }
}

/// `poc/scripts/exp04_embedding.py` の `recall_mrr`（k = 3）。
func recallMRR<ID: Hashable>(queries: [[Float]], docs: [[Float]], docIDs: [ID], relevant: [[ID]], k: Int = 3)
    -> (recall: Double, mrr: Double)
{
    var hits: [Double] = [], rr: [Double] = []
    for (qi, q) in queries.enumerated() {
        let sims = docs.map { EmbeddingVector.cosine(q, $0) }
        // numpy の argsort(-sim) と同じく、同値は元の順（安定ソート）
        let order = sims.indices.sorted { sims[$0] != sims[$1] ? sims[$0] > sims[$1] : $0 < $1 }.map { docIDs[$0] }
        let rel = Set(relevant[qi])
        hits.append(Double(rel.intersection(order.prefix(k)).count) / Double(min(k, rel.count)))
        if let first = order.firstIndex(where: { rel.contains($0) }) { rr.append(1 / Double(first + 1)) } else { rr.append(0) }
    }
    return (hits.reduce(0, +) / Double(hits.count), rr.reduce(0, +) / Double(rr.count))
}

func median(_ x: [Double]) -> Double {
    let s = x.sorted()
    guard !s.isEmpty else { return .nan }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// phys_footprint と、その生涯ピーク（MB）。
func memoryFootprintMB() -> (current: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return (-1, -1) }
    return (Double(info.phys_footprint) / 1e6, Double(info.ledger_phys_footprint_peak) / 1e6)
}

func loadAverage() -> String {
    var l = [Double](repeating: 0, count: 3)
    _ = getloadavg(&l, 3)
    return l.map { String(format: "%.2f", $0) }.joined(separator: " ")
}

/// 計測値を `[metrics]` 付きで出す（報告用に grep する）。
func metric(_ s: String) { print("[metrics] \(s)") }
