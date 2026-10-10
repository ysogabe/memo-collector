// usage: eg2-bench <model_dir> <embed_text_ids.json> <CPU_AND_NE|CPU_AND_GPU|ALL|CPU_ONLY> <out.json>
// model_dir: EmbeddingGemma2Text.mlmodelc（または .mlpackage）・embeddings.bf16・tokenizer.json を含む
import CoreML
import Darwin
import FluidUse
import Foundation

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : -1
}
func peakFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1e6 : -1
}
func median(_ x: [Double]) -> Double { let s = x.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
func now() -> Double { Date().timeIntervalSince1970 }

let args = CommandLine.arguments
let modelDir = URL(fileURLWithPath: args[1])
let items = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any])["items"] as! [[String: Any]]
let units: [String: MLComputeUnits] = ["CPU_AND_NE": .cpuAndNeuralEngine, "CPU_AND_GPU": .cpuAndGPU, "ALL": .all, "CPU_ONLY": .cpuOnly]
let cu = units[args[3]]!
let iso = ISO8601DateFormatter()
var out: [String: Any] = ["started_at": iso.string(from: Date()), "compute_units": args[3], "footprint_start_mb": footprintMB()]

let t0 = now()
let manager = try await EmbeddingGemma2Manager.load(from: modelDir, computeUnits: cu)
out["load_s"] = now() - t0
out["footprint_after_load_mb"] = footprintMB()

// トークナイザ一致（HF の ids と比較）
var tokMatch = 0
var mismatches: [[String: Any]] = []
for it in items {
    let text = it["text"] as! String
    let hf = (it["ids"] as! [Int]).map { Int32($0) }
    let sw = manager.tokenizer.encode(text, maxLength: 512)
    if sw == hf { tokMatch += 1 } else if mismatches.count < 5 { mismatches.append(["kind": it["kind"]!, "i": it["i"]!, "hf_len": hf.count, "swift_len": sw.count]) }
}
out["tokenizer_match"] = "\(tokMatch)/\(items.count)"
out["tokenizer_mismatches"] = mismatches

var t = now()
_ = try await manager.embed(items[0]["text"] as! String)
out["first_predict_s"] = now() - t

// 埋め込み（プロンプトは文字列に既に入っているので .none）
var vectors: [[Float]] = []
for it in items { vectors.append(try await manager.embed(it["text"] as! String)) }
out["vectors"] = vectors.map { $0.map { Double($0) } }
out["kinds"] = items.map { "\($0["kind"]!)\($0["i"]!)" }

// レイテンシ: 1 件ずつ（3 周、各周の中央値）
var bench: [String: Any] = ["started_at": iso.string(from: Date())]
for kind in ["doc", "text_query", "image_query"] {
    let texts = items.filter { ($0["kind"] as! String) == kind }.map { $0["text"] as! String }
    if texts.isEmpty { continue }
    var reps: [Double] = []
    for _ in 0..<3 {
        var lats: [Double] = []
        for s in texts { t = now(); _ = try await manager.embed(s); lats.append(now() - t) }
        reps.append(median(lats))
    }
    bench[kind] = ["median_s_each_rep": reps, "median_s": median(reps), "n": texts.count]
}
// バッチ（pack_256 + 並列 8）: 全 50 件をまとめて
var batchReps: [Double] = []
let all = items.map { $0["text"] as! String }
for _ in 0..<3 { t = now(); _ = try await manager.embed(all); batchReps.append(now() - t) }
bench["batch_all_s_each_rep"] = batchReps
bench["batch_all_per_item_s"] = median(batchReps) / Double(all.count)
bench["finished_at"] = iso.string(from: Date())
out["bench"] = bench
out["footprint_end_mb"] = footprintMB()
out["footprint_peak_mb"] = peakFootprintMB()
try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[4]))
var summary = out
summary.removeValue(forKey: "vectors")
summary.removeValue(forKey: "kinds")
print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
