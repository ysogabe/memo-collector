// EmbeddingGemma 2 の画像・融合埋め込みを Swift + Core ML だけで計算する（FluidUse には未実装の部分）。
// Gemma4ImageProcessor の手順（アスペクト比保持・辺は 48 の倍数・最大 9×280 パッチ、RGB/255、16px パッチを行優先、
// 3×3 プーリング）を CoreGraphics で再現し、vision_280 → 画像トークンを embed_S に差し込む。
//
// usage: eg2-image <model_dir> <embed_reference.json> <screens_dir> <vision CU> <text CU> <out.json> [bicubic|cg] [280|140|70]
//   model_dir: EmbeddingGemma2Text.mlmodelc / EmbeddingGemma2Vision.mlmodelc / embeddings.bf16 /
//              position_embeddings.f16 / tokenizer.json
import CoreGraphics
import CoreML
import Darwin
import FluidUse
import Foundation
import ImageIO

let budget = CommandLine.arguments.count > 8 ? Int(CommandLine.arguments[8])! : 280  // ソフトトークン数 70 / 140 / 280
let H = 512, T = budget, N = 9 * budget, P = 16, K = 3
let SOFT: Int32 = 258_880, BOI: Int32 = 255_999, EOI: Int32 = 258_882
let lengths = [128, 256, 512]
let scale = Float(512).squareRoot()

func now() -> Double { Date().timeIntervalSince1970 }
func median(_ x: [Double]) -> Double { let s = x.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
func footprint() -> (Double, Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return (Double(info.phys_footprint) / 1e6, Double(info.ledger_phys_footprint_peak) / 1e6)
}

let a = CommandLine.arguments
let dir = URL(fileURLWithPath: a[1])
let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[2]))) as! [String: Any]
let screens = URL(fileURLWithPath: a[3])
let units: [String: MLComputeUnits] = ["CPU_AND_NE": .cpuAndNeuralEngine, "CPU_AND_GPU": .cpuAndGPU, "ALL": .all, "CPU_ONLY": .cpuOnly]
let iso = ISO8601DateFormatter()
let resampleMode = a.count > 7 ? a[7] : "bicubic"
var out: [String: Any] = ["started_at": iso.string(from: Date()), "vision_cu": a[4], "text_cu": a[5], "resample": resampleMode, "budget": T]

func load(_ name: String, _ fn: String, _ cu: MLComputeUnits) throws -> MLModel {
    let c = MLModelConfiguration()
    c.computeUnits = cu
    c.functionName = fn
    return try MLModel(contentsOf: dir.appendingPathComponent("\(name).mlmodelc"), configuration: c)
}
var t = now()
let vision = try load("EmbeddingGemma2Vision", "vision_\(T)", units[a[4]]!)
out["load_vision_s"] = now() - t
t = now()
var text: [Int: MLModel] = [:]
for L in lengths { text[L] = try load("EmbeddingGemma2Text", "embed_\(L)", units[a[5]]!) }
out["load_text_s"] = now() - t
let table = try Data(contentsOf: dir.appendingPathComponent("embeddings.bf16"), options: .alwaysMapped)
let posTable = try Data(contentsOf: dir.appendingPathComponent("position_embeddings.f16"))  // [2][1024][768] fp16
let tokenizer = try EmbeddingGemma2Tokenizer(tokenizerJsonURL: dir.appendingPathComponent("tokenizer.json"))

// ---- 画像前処理（HF get_aspect_ratio_preserving_size と同じ式）
func targetSize(h: Int, w: Int) -> (Int, Int) {
    let maxPatches = T * K * K, side = K * P
    let factor = (Double(maxPatches * P * P) / Double(h * w)).squareRoot()
    var th = Int(floor(factor * Double(h) / Double(side))) * side
    var tw = Int(floor(factor * Double(w) / Double(side))) * side
    let maxSide = (maxPatches / (K * K)) * side
    if th == 0 { th = side; tw = min(Int(floor(Double(w) / Double(h))) * side, maxSide) }
    else if tw == 0 { tw = side; th = min(Int(floor(Double(h) / Double(w))) * side, maxSide) }
    return (th, tw)
}


// 画像を RGBA8（sRGB、先頭行 = 上端）で取り出す
func rgba(_ img: CGImage) -> [UInt8] {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}
// CoreGraphics の高品質補間（HF とは別アルゴリズム。差の大きさを見るための比較用）
func resizeCG(_ img: CGImage, _ tw: Int, _ th: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: tw * th * 4)
    let ctx = CGContext(data: &buf, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: tw, height: th))
    return buf
}
// PIL / torchvision(antialias=True) と同じ分離型 bicubic（a = -0.5、縮小時はカーネルを scale 倍に広げる）。
// 各パスの出力を uint8 に丸める点も PIL に合わせる。
func resizeBicubic(_ img: CGImage, _ tw: Int, _ th: Int) -> [UInt8] {
    let src = rgba(img), sw = img.width, sh = img.height
    func cubic(_ x: Double) -> Double {
        let a = -0.5, x = abs(x)
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }
    func weights(_ inSize: Int, _ outSize: Int) -> [(Int, [Double])] {
        let scale = Double(inSize) / Double(outSize)
        let fs = max(scale, 1), support = 2 * fs
        return (0..<outSize).map { i in
            let center = (Double(i) + 0.5) * scale
            let lo = max(Int(center - support + 0.5), 0), hi = min(Int(center + support + 0.5), inSize)
            var w = (lo..<hi).map { cubic((Double($0) - center + 0.5) / fs) }
            let sum = w.reduce(0, +)
            if sum != 0 { w = w.map { $0 / sum } }
            return (lo, w)
        }
    }
    func clip(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
    let wx = weights(sw, tw), wy = weights(sh, th)
    var mid = [UInt8](repeating: 0, count: tw * sh * 4)
    for y in 0..<sh {
        for x in 0..<tw {
            let (lo, w) = wx[x]
            for ch in 0..<3 {
                var acc = 0.0
                for (k, wk) in w.enumerated() { acc += wk * Double(src[(y * sw + lo + k) * 4 + ch]) }
                mid[(y * tw + x) * 4 + ch] = clip(acc)
            }
        }
    }
    var dst = [UInt8](repeating: 0, count: tw * th * 4)
    for y in 0..<th {
        let (lo, w) = wy[y]
        for x in 0..<tw {
            for ch in 0..<3 {
                var acc = 0.0
                for (k, wk) in w.enumerated() { acc += wk * Double(mid[((lo + k) * tw + x) * 4 + ch]) }
                dst[(y * tw + x) * 4 + ch] = clip(acc)
            }
        }
    }
    return dst
}

struct Prepared { let patches, positions, pool, valid, pe: MLMultiArray; let tokens: Int }

func prepare(_ url: URL) throws -> Prepared {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let (th, tw) = targetSize(h: img.height, w: img.width)
    let px = resampleMode == "cg" ? resizeCG(img, tw, th) : resizeBicubic(img, tw, th)  // RGBA8、先頭行 = 上端
    let ph = th / P, pw = tw / P, n = ph * pw
    let patches = try MLMultiArray(shape: [1, NSNumber(value: N), 768], dataType: .float16)
    let positions = try MLMultiArray(shape: [1, NSNumber(value: N), 2], dataType: .float16)
    let pool = try MLMultiArray(shape: [NSNumber(value: T), NSNumber(value: N)], dataType: .float16)
    let valid = try MLMultiArray(shape: [1, NSNumber(value: N)], dataType: .float16)
    let pe = try MLMultiArray(shape: [1, NSNumber(value: N), 768], dataType: .float16)
    let pp = patches.dataPointer.assumingMemoryBound(to: Float16.self)
    let pos = positions.dataPointer.assumingMemoryBound(to: Float16.self)
    let pl = pool.dataPointer.assumingMemoryBound(to: Float16.self)
    let vd = valid.dataPointer.assumingMemoryBound(to: Float16.self)
    let pep = pe.dataPointer.assumingMemoryBound(to: Float16.self)
    pp.update(repeating: 0, count: N * 768); pl.update(repeating: 0, count: T * N)
    vd.update(repeating: 0, count: N); pep.update(repeating: 0, count: N * 768)
    for i in 0..<N { pos[2 * i] = -1; pos[2 * i + 1] = -1 }
    let gw = pw / K
    posTable.withUnsafeBytes { raw in
        let tab = raw.bindMemory(to: Float16.self)
        for py in 0..<ph {
            for pxi in 0..<pw {
                let i = py * pw + pxi
                for r in 0..<P {
                    for c in 0..<P {
                        let s = ((py * P + r) * tw + (pxi * P + c)) * 4
                        for ch in 0..<3 { pp[i * 768 + (r * P + c) * 3 + ch] = Float16(Float(px[s + ch]) / 255) }
                    }
                }
                pos[2 * i] = Float16(Float(pxi)); pos[2 * i + 1] = Float16(Float(py))
                vd[i] = 1
                pl[((py / K) * gw + pxi / K) * N + i] = Float16(Float(1.0 / 9.0))
                for d in 0..<768 { pep[i * 768 + d] = Float16(Float(tab[pxi * 768 + d]) + Float(tab[1024 * 768 + py * 768 + d])) }
            }
        }
    }
    return Prepared(patches: patches, positions: positions, pool: pool, valid: valid, pe: pe, tokens: n / (K * K))
}

func visionTokens(_ p: Prepared) throws -> MLMultiArray {
    let o = try vision.prediction(from: MLDictionaryFeatureProvider(dictionary: [
        "patches": p.patches, "positions": p.positions, "pool": p.pool, "valid": p.valid, "position_embeddings": p.pe,
    ]))
    return o.featureValue(for: "image_tokens")!.multiArrayValue!
}

// ---- テキスト塔: ids（SOFT はスキップ）と画像トークンを並べて embed_S
func embed(ids: [Int32], image: MLMultiArray?) throws -> [Float] {
    let L = lengths.first { $0 >= ids.count }!
    let x = try MLMultiArray(shape: [1, NSNumber(value: L), NSNumber(value: H)], dataType: .float16)
    let m = try MLMultiArray(shape: [1, NSNumber(value: L)], dataType: .float16)
    let xp = x.dataPointer.assumingMemoryBound(to: Float16.self), mp = m.dataPointer.assumingMemoryBound(to: Float16.self)
    xp.update(repeating: 0, count: L * H)
    var k = 0
    let stride = image.map { $0.strides[$0.strides.count - 2].intValue } ?? 0
    table.withUnsafeBytes { raw in
        let bf = raw.bindMemory(to: UInt16.self)
        for (j, id) in ids.enumerated() {
            mp[j] = 1
            if id == SOFT, let image {
                for d in 0..<H {
                    let idx = k * stride + d
                    xp[j * H + d] = image.dataType == .float16 ? image.dataPointer.assumingMemoryBound(to: Float16.self)[idx]
                        : Float16(image.dataPointer.assumingMemoryBound(to: Float.self)[idx])
                }
                k += 1
            } else {
                for d in 0..<H { xp[j * H + d] = Float16(Float(bitPattern: UInt32(bf[Int(id) * H + d]) << 16) * scale) }
            }
        }
    }
    for j in ids.count..<L { mp[j] = 0 }
    let o = try text[L]!.prediction(from: MLDictionaryFeatureProvider(dictionary: ["inputs_embeds": x, "attention_mask": m]))
    let v = o.featureValue(for: "embedding")!.multiArrayValue!
    var r = (0..<768).map { v.dataType == .float16 ? Float(v.dataPointer.assumingMemoryBound(to: Float16.self)[$0]) : v.dataPointer.assumingMemoryBound(to: Float.self)[$0] }
    let norm = r.reduce(0) { $0 + $1 * $1 }.squareRoot()
    r = r.map { $0 / norm }
    return r
}

func imageIds(_ n: Int) -> [Int32] { [tokenizer.bosId, BOI] + Array(repeating: SOFT, count: n) + [EOI, tokenizer.eosId] }
func fusedIds(_ s: String, _ n: Int) -> [Int32] {
    // HF は "<|image|>" を boi + soft×n + eoi の文字列に置き換えてからトークナイズする。直前の空白は残す。
    let head = s.hasSuffix("<|image|>") ? String(s.dropLast("<|image|>".count)) : s
    var ids = tokenizer.encode(head, maxLength: 512)
    if ids.last == tokenizer.eosId { ids.removeLast() }
    return ids + [BOI] + Array(repeating: SOFT, count: n) + [EOI, tokenizer.eosId]
}

let scrIds = meta["scr_ids"] as! [String]
let fusedTexts = meta["fused_texts"] as! [String]
let capScreens = meta["cap_screens"] as! [String]

t = now()
let p0 = try prepare(screens.appendingPathComponent("\(scrIds[0]).png"))
_ = try embed(ids: imageIds(p0.tokens), image: try visionTokens(p0))
out["first_image_s"] = now() - t

var images: [[Float]] = [], fused: [[Float]] = [], fusedIdsOut: [[Int32]] = [], soft: [Int] = []
// Core ML の出力・入力は autorelease されるので、1 件ごとに pool を抜ける（抜けないとフットプリントが積み上がる）
for s in scrIds {
    try autoreleasepool {
        let p = try prepare(screens.appendingPathComponent("\(s).png"))
        soft.append(p.tokens)
        images.append(try embed(ids: imageIds(p.tokens), image: try visionTokens(p)))
    }
}
for (txt, s) in zip(fusedTexts, capScreens) {
    try autoreleasepool {
        let p = try prepare(screens.appendingPathComponent("\(s).png"))
        let ids = fusedIds(txt, p.tokens)
        fusedIdsOut.append(ids)
        fused.append(try embed(ids: ids, image: try visionTokens(p)))
    }
}
out["soft_tokens"] = soft
out["fused_ids"] = fusedIdsOut.map { $0.map { Int($0) } }
out["images"] = images.map { $0.map { Double($0) } }
out["fused"] = fused.map { $0.map { Double($0) } }

var bench: [String: Any] = ["started_at": iso.string(from: Date())]
for (name, list) in [("image", scrIds.map { ($0, nil as String?) }), ("fused", Array(zip(capScreens, fusedTexts.map { Optional($0) })))] {
    var reps: [Double] = [], pre: [Double] = [], vis: [Double] = []
    for _ in 0..<3 {
        var lats: [Double] = [], lp: [Double] = [], lv: [Double] = []
        for (s, txt) in list {
            try autoreleasepool {
                let t0 = now()
                let p = try prepare(screens.appendingPathComponent("\(s).png"))
                let t1 = now()
                let v = try visionTokens(p)
                let t2 = now()
                _ = try embed(ids: txt.map { fusedIds($0, p.tokens) } ?? imageIds(p.tokens), image: v)
                lats.append(now() - t0); lp.append(t1 - t0); lv.append(t2 - t1)
            }
        }
        reps.append(median(lats)); pre.append(median(lp)); vis.append(median(lv))
    }
    bench[name] = ["median_s_each_rep": reps, "median_s": median(reps), "preprocess_median_s": median(pre), "vision_median_s": median(vis)]
}
bench["finished_at"] = iso.string(from: Date())
out["bench"] = bench
let (fp, peak) = footprint()
out["footprint_end_mb"] = fp
out["footprint_peak_mb"] = peak
try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: URL(fileURLWithPath: a[6]))
print("ok", out["load_vision_s"]!, out["load_text_s"]!, out["first_image_s"]!, soft, bench, fp, peak)
