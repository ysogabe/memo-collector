// d1-3B（言語モデル部分）を MLX Swift (mlx-swift-lm の LFM2) で 1 forward し、
// 最終位置 logits を d1 の readout（選択肢トークン群の max-pool → softmax）で確率にする。
//
// usage: d1-swift <reference.json> <model_dir> <out.json>
//   - reference.json は scripts/d1_reference.py の出力（token ids / readout groups / torch の確率）
//   - token ids はファイルのものをそのまま使う（数値一致）。別途 swift-transformers の
//     トークナイザで prompt 文字列を encode し、ids と一致するかを検査する。

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

struct QRef: Codable {
    let prompt: String
    let ids: [Int]
    let groups: [[Int]]
    let chain_probs: [Double]
    let tree_probs: [Double]
}

struct RowRef: Codable {
    let text: String
    let id: Int
    let split: String
    let gold_intent: String
    let gold_deadline: Bool?
    let labels: [String]
    let q: [String: QRef]
}

struct RefFile: Codable { let rows: [RowRef] }

func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1e6 : -1
}

func readout(_ logits: [Float], _ ids: [Int], _ groups: [[Int]]) -> [Double] {
    var at: [Int: Double] = [:]
    for (i, id) in ids.enumerated() { at[id] = Double(logits[i]) }
    let s = groups.map { g in g.map { at[$0]! }.max()! }
    let m = s.max()!
    let e = s.map { exp($0 - m) }
    let z = e.reduce(0, +)
    return e.map { $0 / z }
}

func argmax(_ p: [Double]) -> Int { p.indices.max { p[$0] < p[$1] }! }

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: d1-swift <reference.json> <model_dir> <out.json>")
    exit(2)
}
let ref = try JSONDecoder().decode(RefFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let modelDir = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])

let t0 = Date()
let cfgData = try Data(contentsOf: modelDir.appendingPathComponent("config.json"))
let cfg = try JSONDecoder().decode(LFM2Configuration.self, from: cfgData)
let base = try JSONDecoder().decode(BaseConfiguration.self, from: cfgData)
let model = LFM2Model(cfg)
try loadWeights(modelDirectory: modelDir, model: model, quantization: base.quantization,
                perLayerQuantization: base.perLayerQuantization)
let loadS = Date().timeIntervalSince(t0)
let memAfterLoad = Double(Memory.activeMemory) / 1e6

@MainActor func optionLogits(_ ids: [Int], _ groups: [[Int]]) -> ([Float], [Int]) {
    let x = MLXArray(ids.map { Int32($0) }).reshaped([1, ids.count])
    let logits = model(x, cache: nil)[0, ids.count - 1].asType(.float32)
    let flat = Array(Set(groups.flatMap { $0 })).sorted()
    let sel = logits[MLXArray(flat.map { Int32($0) })]
    eval(sel)
    return (sel.asArray(Float.self), flat)
}

// 2 質問を右パディングで 1 バッチにする（因果 conv / 因果 attention なので pad は実トークンへ漏れない）
@MainActor func optionLogitsBatch(_ seqs: [[Int]], _ groups: [[[Int]]]) -> [([Float], [Int])] {
    let n = seqs.map { $0.count }.max()!
    let padded = seqs.flatMap { $0.map { Int32($0) } + Array(repeating: Int32(124893), count: n - $0.count) }
    let logits = model(MLXArray(padded).reshaped([seqs.count, n]), cache: nil)
    var out: [([Float], [Int])] = []
    var sels: [MLXArray] = []
    var flats: [[Int]] = []
    for (b, sq) in seqs.enumerated() {
        let flat = Array(Set(groups[b].flatMap { $0 })).sorted()
        sels.append(logits[b, sq.count - 1].asType(.float32)[MLXArray(flat.map { Int32($0) })])
        flats.append(flat)
    }
    eval(sels)
    for (sel, flat) in zip(sels, flats) { out.append((sel.asArray(Float.self), flat)) }
    return out
}

// ---- tokenizer parity ----
let tokenizer = try await AutoTokenizer.from(modelFolder: modelDir)
var tokMismatch: [String] = []
var tokFirst: [String: [Int]] = [:]
var swiftIds: [String: [Int]] = [:]
let useSwiftTokens = ProcessInfo.processInfo.environment["D1_USE_SWIFT_TOKENS"] != nil
for r in ref.rows {
    for (name, q) in r.q {
        let enc = tokenizer.encode(text: q.prompt, addSpecialTokens: false)
        swiftIds["\(r.id)/\(name)"] = enc
        if enc != q.ids {
            tokMismatch.append("\(r.id)/\(name) swift=\(enc.count) ref=\(q.ids.count)")
            if tokFirst.isEmpty { tokFirst = ["swift": enc, "ref": q.ids] }
        }
    }
}

if ProcessInfo.processInfo.environment["D1_TOKENIZER_ONLY"] != nil {
    let textIds = ref.rows.map { tokenizer.encode(text: $0.text, addSpecialTokens: false) }
    try JSONSerialization.data(withJSONObject: ["mismatch": tokMismatch, "first": tokFirst, "text_ids": textIds]).write(to: outURL)
    print("tokenizer mismatches:", tokMismatch.count, "/", ref.rows.count * 2)
    exit(0)
}
// ---- numerics ----
var rowsOut: [[String: Any]] = []
for r in ref.rows {
    var o: [String: Any] = ["id": r.id, "split": r.split, "gold_intent": r.gold_intent,
                            "gold_deadline": r.gold_deadline as Any]
    for name in ["intent", "deadline"] {
        let q = r.q[name]!
        let ids = useSwiftTokens ? swiftIds["\(r.id)/\(name)"]! : q.ids
        let (lg, flat) = optionLogits(ids, q.groups)
        let p = readout(lg, flat, q.groups)
        o[name] = ["probs": p, "chain_probs": q.chain_probs, "tree_probs": q.tree_probs]
    }
    rowsOut.append(o)
}

func summarize(_ sel: [[String: Any]], labels: [String]) -> [String: Any] {
    var s: [String: Any] = [:]
    for name in ["intent", "deadline"] {
        for refk in ["chain_probs", "tree_probs"] {
            var maxd = 0.0, agree = 0
            for x in sel {
                let q = x[name] as! [String: [Double]]
                let a = q["probs"]!, b = q[refk]!
                maxd = max(maxd, zip(a, b).map { abs($0 - $1) }.max()!)
                if argmax(a) == argmax(b) { agree += 1 }
            }
            s["\(name)_vs_\(refk)"] = ["max_abs_dp": maxd, "top1_agree": "\(agree)/\(sel.count)"]
        }
    }
    let acc = sel.filter { x in
        labels[argmax((x["intent"] as! [String: [Double]])["probs"]!)] == (x["gold_intent"] as! String)
    }.count
    s["intent_accuracy"] = "\(acc)/\(sel.count)"
    return s
}
let labels = ref.rows[0].labels
var summary: [String: Any] = [:]
for sp in ["dev", "holdout"] { summary[sp] = summarize(rowsOut.filter { ($0["split"] as! String) == sp }, labels: labels) }
summary["all"] = summarize(rowsOut, labels: labels)

// ---- latency: 1 注釈 = intent + deadline の 2 forward、3 周の中央値 ----
let iso = ISO8601DateFormatter()
var reps: [[String: Double]] = []
let started = iso.string(from: Date())
for _ in 0..<3 {
    var lats: [Double] = []
    for r in ref.rows {
        let t = Date()
        for name in ["intent", "deadline"] { _ = optionLogits(r.q[name]!.ids, r.q[name]!.groups) }
        lats.append(Date().timeIntervalSince(t))
    }
    lats.sort()
    reps.append(["median_s": lats[lats.count / 2], "p90_s": lats[Int(0.9 * Double(lats.count - 1))]])
}
var repsBatch: [[String: Double]] = []
var batchMaxDp = 0.0
for rep in 0..<3 {
    var lats: [Double] = []
    for (ri, r) in ref.rows.enumerated() {
        let qs = ["intent", "deadline"].map { r.q[$0]! }
        let t = Date()
        let res = optionLogitsBatch(qs.map { $0.ids }, qs.map { $0.groups })
        lats.append(Date().timeIntervalSince(t))
        if rep == 0 {
            for (k, name) in ["intent", "deadline"].enumerated() {
                let p = readout(res[k].0, res[k].1, qs[k].groups)
                let single = (rowsOut[ri][name] as! [String: [Double]])["probs"]!
                batchMaxDp = max(batchMaxDp, zip(p, single).map { abs($0 - $1) }.max()!)
            }
        }
    }
    lats.sort()
    repsBatch.append(["median_s": lats[lats.count / 2], "p90_s": lats[Int(0.9 * Double(lats.count - 1))]])
}
let finished = iso.string(from: Date())

let out: [String: Any] = [
    "model_dir": modelDir.path, "used_swift_tokens": useSwiftTokens, "load_s": loadS, "active_mem_after_load_mb": memAfterLoad,
    "peak_mem_mb": Double(Memory.peakMemory) / 1e6, "rss_mb": rssMB(),
    "tokenizer_mismatch": tokMismatch, "tokenizer_first_mismatch": tokFirst, "tokenizer_checked": ref.rows.count * 2,
    "summary": summary, "bench": ["started_at": started, "finished_at": finished, "reps": reps, "reps_batch2": repsBatch,
              "batch2_vs_single_max_abs_dp": batchMaxDp],
    "rows": rowsOut,
]
try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: outURL)
let pretty = try JSONSerialization.data(
    withJSONObject: ["summary": summary, "reps": reps, "reps_batch2": repsBatch, "batch_dp": batchMaxDp, "load_s": loadS, "mem": memAfterLoad,
                     "peak": Double(Memory.peakMemory) / 1e6, "tok_mismatch": tokMismatch.count],
    options: [.prettyPrinted, .sortedKeys])
print(String(data: pretty, encoding: .utf8)!)
