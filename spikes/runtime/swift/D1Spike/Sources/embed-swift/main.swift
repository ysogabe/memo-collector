// EmbeddingGemma 2 のテキストタワーを MLX Swift で手書き移植したスパイク（mlx-swift-lm に embedding_gemma2 が無いため）。
// 仕様は mlx-vlm main の models/embedding_gemma2/language.py + embedding_gemma2.py（mean pooling → L2 正規化）。
//
// usage: embed-swift <text_tower_dir> <embed_text_ids.json> <out.json>
//   text_tower_dir: language_model.* だけを抜いた safetensors + config.json + tokenizer.json
//   embed_text_ids.json: scripts/embed_export_ids.py の出力（HF の token ids と PyTorch 参照埋め込み）

import Foundation
import MLX
import MLXNN
import Tokenizers

struct Item: Codable { let kind: String; let i: Int; let text: String; let ids: [Int]; let ref: [Float] }
struct ItemsFile: Codable { let items: [Item] }

struct TextConfig {
    let hidden: Int, layers: Int, heads: Int, kvHeads: Int, headDim: Int, eps: Float
    let pleWidth: Int, slidingWindow: Int
    let layerTypes: [String]
    let perLayer: [String: [String: Int]]
    let ropeTheta: [String: Float]
}

func loadConfig(_ url: URL) throws -> TextConfig {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let t = root["text_config"] as! [String: Any]
    let rp = t["rope_parameters"] as! [String: [String: Any]]
    return TextConfig(
        hidden: t["hidden_size"] as! Int, layers: t["num_hidden_layers"] as! Int,
        heads: t["num_attention_heads"] as! Int, kvHeads: t["num_key_value_heads"] as! Int,
        headDim: t["head_dim"] as! Int, eps: Float(t["rms_norm_eps"] as! Double),
        pleWidth: t["hidden_size_per_layer_input"] as! Int, slidingWindow: t["sliding_window"] as! Int,
        layerTypes: t["layer_types"] as! [String],
        perLayer: (t["per_layer_config"] as? [String: [String: Int]]) ?? [:],
        ropeTheta: rp.mapValues { Float(($0["rope_theta"] as! NSNumber).doubleValue) })
}

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: embed-swift <text_tower_dir> <ids.json> <out.json>"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let itemsFile = try JSONDecoder().decode(ItemsFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let outURL = URL(fileURLWithPath: args[3])

let t0 = Date()
let cfg = try loadConfig(dir.appendingPathComponent("config.json"))
let W = try loadArrays(url: dir.appendingPathComponent("model.safetensors"))
eval(Array(W.values))
let loadS = Date().timeIntervalSince(t0)
@MainActor func w(_ k: String) -> MLXArray { W["language_model." + k]! }

@MainActor func linear(_ x: MLXArray, _ k: String) -> MLXArray { matmul(x, w(k + ".weight").T) }
@MainActor func rms(_ x: MLXArray, _ k: String?) -> MLXArray {
    if let k { return MLXFast.rmsNorm(x, weight: w(k + ".weight"), eps: cfg.eps) }
    return MLXFast.rmsNorm(x, weight: MLXArray.ones([x.dim(-1)], dtype: x.dtype), eps: cfg.eps)
}

// RoPE: fp32 の角度、cos/sin は活性の dtype に丸める（mlx-vlm の RotaryEmbedding と同じ）
func rope(_ x: MLXArray, dim: Int, theta: Float) -> MLXArray {  // x: (B, H, T, D)
    let T = x.dim(2)
    let inv = 1.0 / pow(MLXArray(theta), MLXArray(stride(from: 0, to: dim, by: 2).map { Float($0) }) / Float(dim))
    let ang = MLXArray(0 ..< T).asType(.float32)[0..., .newAxis] * inv[.newAxis, 0...]
    let a = concatenated([ang, ang], axis: -1)
    let c = cos(a).asType(x.dtype), s = sin(a).asType(x.dtype)
    let half = dim / 2
    let rotated = concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
    return x * c + rotated * s
}

@MainActor func embed(_ ids: [Int]) -> MLXArray {
    let T = ids.count
    precondition(T <= cfg.slidingWindow, "spike: sliding mask is not applied; inputs must be <= window")
    let x0 = w("embed_tokens.weight")[MLXArray(ids.map { Int32($0) })][.newAxis]  // (1, T, 512)
    var h = x0 * MLXArray(Float(cfg.hidden).squareRoot()).asType(x0.dtype)
    // Per-Layer Embeddings
    var ple = linear(h, "ple.per_layer_model_projection") * MLXArray(pow(Float(cfg.hidden), -0.5)).asType(h.dtype)
    ple = ple.reshaped([1, T, cfg.layers, cfg.pleWidth])
    ple = rms(ple, "ple.per_layer_projection_norm")
    for i in 0 ..< cfg.layers {
        let p = "layers.\(i)."
        let o = cfg.perLayer[String(format: "%02d", i)] ?? [:]
        let hd = o["head_dim"] ?? cfg.headDim
        let nh = o["num_attention_heads"] ?? cfg.heads
        let nkv = o["num_key_value_heads"] ?? cfg.kvHeads
        let theta = cfg.ropeTheta[cfg.layerTypes[i]]!
        // attention（双方向、scale=1、q/k norm、v は scale なし RMSNorm）
        let xin = rms(h, p + "input_layernorm")
        var q = rms(linear(xin, p + "self_attn.q_proj").reshaped([1, T, nh, hd]), p + "self_attn.q_norm")
        var k = rms(linear(xin, p + "self_attn.k_proj").reshaped([1, T, nkv, hd]), p + "self_attn.k_norm")
        let v = rms(linear(xin, p + "self_attn.v_proj").reshaped([1, T, nkv, hd]), nil).transposed(0, 2, 1, 3)
        q = rope(q.transposed(0, 2, 1, 3), dim: hd, theta: theta)
        k = rope(k.transposed(0, 2, 1, 3), dim: hd, theta: theta)
        let att = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1.0, mask: .none)
        h = h + rms(linear(att.transposed(0, 2, 1, 3).reshaped([1, T, nh * hd]), p + "self_attn.o_proj"),
                    p + "post_attention_layernorm")
        // MLP（gelu tanh 近似）
        let f = rms(h, p + "pre_feedforward_layernorm")
        let m = linear(geluApproximate(linear(f, p + "mlp.gate_proj")) * linear(f, p + "mlp.up_proj"), p + "mlp.down_proj")
        h = h + rms(m, p + "post_feedforward_layernorm")
        // PLE ブロック
        let gate = geluApproximate(linear(h, p + "ple_block.per_layer_input_gate")) * ple[0..., 0..., i, 0...]
        h = h + rms(linear(gate, p + "ple_block.per_layer_projection"), p + "ple_block.post_per_layer_input_norm")
        h = h * w(p + "layer_scalar")
    }
    let proj = linear(rms(h, "norm"), "embedding_projection")  // (1, T, 768)
    let pooled = proj.asType(.float32).mean(axis: 1)[0]
    let e = pooled / sqrt((pooled * pooled).sum())
    eval(e)
    return e
}

let tokenizer = try await AutoTokenizer.from(modelFolder: dir)
var tokMismatch = 0
var cosAll: [String: [Float]] = [:]
var embs: [[Float]] = []
for it in itemsFile.items {
    let enc = tokenizer.encode(text: it.text)
    if enc != it.ids { tokMismatch += 1 }
    let e = embed(it.ids).asArray(Float.self)
    embs.append(e)
    let c = zip(e, it.ref).map { $0 * $1 }.reduce(0, +)
    cosAll[it.kind, default: []].append(c)
}
let iso = ISO8601DateFormatter()
let started = iso.string(from: Date())
var reps: [Double] = []
for _ in 0 ..< 3 {
    var lats: [Double] = []
    for it in itemsFile.items where it.kind == "doc" {
        let t = Date()
        _ = embed(it.ids)
        lats.append(Date().timeIntervalSince(t))
    }
    lats.sort()
    reps.append(lats[lats.count / 2])
}
let out: [String: Any] = [
    "load_s": loadS, "active_mem_mb": Double(Memory.activeMemory) / 1e6, "peak_mem_mb": Double(Memory.peakMemory) / 1e6,
    "tokenizer_mismatch": tokMismatch, "n": itemsFile.items.count,
    "cos_min": cosAll.mapValues { $0.min()! }, "cos_mean": cosAll.mapValues { $0.reduce(0, +) / Float($0.count) },
    "bench_doc_median_s_each_rep": reps, "bench_started_at": started, "bench_finished_at": iso.string(from: Date()),
    "embeddings": embs,
]
try JSONSerialization.data(withJSONObject: out).write(to: outURL)
print("cos_min", cosAll.mapValues { $0.min()! }, "tok_mismatch", tokMismatch, "/", itemsFile.items.count, "reps", reps,
      "load", loadS, "peak", Double(Memory.peakMemory) / 1e6)
