@preconcurrency import CoreML
import CoreGraphics
import Foundation

/// 画像トークン数（Gemma 4 の画像プロセッサの `max_soft_tokens`）。Core ML の関数 `vision_70/140/280` に対応する。
///
/// 値を変えると埋め込みの中身が変わる（参照の PyTorch は 280）。**索引は 1 つの値に揃える**こと（変えたら作り直し）。
public enum ImageTokenBudget: Int, CaseIterable, Codable, Sendable {
    case tokens70 = 70
    case tokens140 = 140
    /// 既定。参照（sentence-transformers）と同じ。
    case tokens280 = 280

    /// 視覚塔に入れるパッチ数の上限（トークン 1 個 = 3×3 パッチ）。
    var maxPatches: Int { rawValue * ImagePreprocessor.poolingKernel * ImagePreprocessor.poolingKernel }
    /// Core ML の関数名。
    var functionName: String { "vision_\(rawValue)" }
}

/// Gemma 4 の画像前処理（`Gemma4ImageProcessor`）を Swift で再現する。
///
/// 1. 色空間を sRGB の 8bit RGB にする（ScreenCaptureKit の Display P3・Retina の画像もここで揃う）
/// 2. アスペクト比を保って縮小（辺は 48 の倍数、パッチ数は `9 × トークン数` 以下）。**HF と同じ分離型 bicubic**
///    （a = −0.5、縮小時はカーネル幅を拡大、各パス後に uint8 へ丸め）。CoreGraphics の補間ではコサインが 0.9938 まで落ちる
/// 3. RGB / 255 を 16×16 のパッチ（行優先、各パッチ内は [行][列][RGB]）に並べる。モデル側で 2x − 1 する
/// 4. パッチ位置 (x, y)・位置埋め込み（`position_embeddings.f16` の table[0][x] + table[1][y]）・有効フラグ・
///    3×3 平均プーリングの行列を作る
///
/// 出典: `spikes/fluid/swift/FluidBench/Sources/eg2-image/main.swift`（HF とソフトトークン数 14/14、融合列 30/30 一致）。
enum ImagePreprocessor {
    static let patchSize = 16
    static let poolingKernel = 3
    /// パッチ 1 個の値の数（16 × 16 × RGB）。
    static let patchValues = patchSize * patchSize * 3
    /// 位置埋め込み表の 1 軸あたりの行数（`position_embeddings.f16` は [2][1024][768] の fp16）。
    static let positionTableRows = 1024

    /// 視覚塔の入力 1 件分。
    struct Prepared {
        let patches: MLMultiArray  // [1, N, 768] fp16
        let positions: MLMultiArray  // [1, N, 2] fp16（パディングは −1）
        let pool: MLMultiArray  // [T, N] fp16
        let valid: MLMultiArray  // [1, N] fp16
        let positionEmbeddings: MLMultiArray  // [1, N, 768] fp16
        /// 実際の画像トークン数（≤ 予算。縮小後の大きさで決まる）。
        let softTokens: Int
        let resizedWidth: Int
        let resizedHeight: Int
    }

    // MARK: - 大きさ

    /// HF `get_aspect_ratio_preserving_size` と同じ式。戻り値は (高さ, 幅)。
    static func targetSize(height h: Int, width w: Int, budget: ImageTokenBudget) -> (height: Int, width: Int) {
        let maxPatches = budget.maxPatches
        let side = poolingKernel * patchSize
        let factor = (Double(maxPatches * patchSize * patchSize) / Double(h * w)).squareRoot()
        var th = Int(floor(factor * Double(h) / Double(side))) * side
        var tw = Int(floor(factor * Double(w) / Double(side))) * side
        let maxSide = (maxPatches / (poolingKernel * poolingKernel)) * side
        if th == 0 {
            th = side
            tw = min(Int(floor(Double(w) / Double(h))) * side, maxSide)
        } else if tw == 0 {
            tw = side
            th = min(Int(floor(Double(h) / Double(w))) * side, maxSide)
        }
        return (th, tw)
    }

    // MARK: - 色空間

    /// 画像を sRGB・8bit・RGBX（先頭行 = 上端、X は未使用）で取り出す。色空間が違えば CoreGraphics が色変換する。
    /// アルファは捨てる（黒の上に合成される。スクショは不透明なので影響しない）。
    static func srgbRGBX(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw EmbeddingError.invalidImage("empty image")
        }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw EmbeddingError.invalidImage("cannot create an sRGB bitmap context") }
        return buf
    }

    // MARK: - bicubic

    /// 1 軸ぶんの重み（出力位置ごとに、入力の開始位置とタップ数、平らに並べた重み）。
    struct AxisWeights {
        var start: [Int]
        var count: [Int]
        var offset: [Int]
        var weights: [Double]
    }

    /// PIL の `precompute_coeffs` と同じ（a = −0.5、縮小時はサポートを scale 倍、重みは和で正規化）。
    static func axisWeights(inSize: Int, outSize: Int) -> AxisWeights {
        func cubic(_ x: Double) -> Double {
            let a = -0.5, x = abs(x)
            if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
            if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
            return 0
        }
        let scale = Double(inSize) / Double(outSize)
        let fs = max(scale, 1), support = 2 * fs
        var r = AxisWeights(start: [], count: [], offset: [], weights: [])
        r.start.reserveCapacity(outSize)
        r.count.reserveCapacity(outSize)
        r.offset.reserveCapacity(outSize)
        for i in 0..<outSize {
            let center = (Double(i) + 0.5) * scale
            let lo = max(Int(center - support + 0.5), 0), hi = min(Int(center + support + 0.5), inSize)
            var w = (lo..<hi).map { cubic((Double($0) - center + 0.5) / fs) }
            let sum = w.reduce(0, +)
            if sum != 0 { w = w.map { $0 / sum } }
            r.start.append(lo)
            r.count.append(w.count)
            r.offset.append(r.weights.count)
            r.weights.append(contentsOf: w)
        }
        return r
    }

    @inline(__always) static func clip8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    /// RGBX（4 バイト/画素）を分離型 bicubic で縮小する。横 → 縦の順で、各パスの出力を uint8 に丸める（PIL と同じ）。
    static func resizeBicubic(rgbx src: [UInt8], width sw: Int, height sh: Int, toWidth tw: Int, toHeight th: Int) -> [UInt8] {
        let wx = axisWeights(inSize: sw, outSize: tw), wy = axisWeights(inSize: sh, outSize: th)
        var mid = [UInt8](repeating: 0, count: tw * sh * 4)
        var dst = [UInt8](repeating: 0, count: tw * th * 4)
        src.withUnsafeBufferPointer { s in
            mid.withUnsafeMutableBufferPointer { m in
                wx.weights.withUnsafeBufferPointer { wts in
                    for y in 0..<sh {
                        let row = y * sw
                        for x in 0..<tw {
                            let lo = wx.start[x], n = wx.count[x], off = wx.offset[x]
                            var r = 0.0, g = 0.0, b = 0.0
                            for k in 0..<n {
                                let wk = wts[off + k], p = (row + lo + k) * 4
                                r += wk * Double(s[p]); g += wk * Double(s[p + 1]); b += wk * Double(s[p + 2])
                            }
                            let q = (y * tw + x) * 4
                            m[q] = clip8(r); m[q + 1] = clip8(g); m[q + 2] = clip8(b)
                        }
                    }
                }
            }
        }
        mid.withUnsafeBufferPointer { m in
            dst.withUnsafeMutableBufferPointer { d in
                wy.weights.withUnsafeBufferPointer { wts in
                    for y in 0..<th {
                        let lo = wy.start[y], n = wy.count[y], off = wy.offset[y]
                        for x in 0..<tw {
                            var r = 0.0, g = 0.0, b = 0.0
                            for k in 0..<n {
                                let wk = wts[off + k], p = ((lo + k) * tw + x) * 4
                                r += wk * Double(m[p]); g += wk * Double(m[p + 1]); b += wk * Double(m[p + 2])
                            }
                            let q = (y * tw + x) * 4
                            d[q] = clip8(r); d[q + 1] = clip8(g); d[q + 2] = clip8(b)
                        }
                    }
                }
            }
        }
        return dst
    }

    // MARK: - パッチ化

    /// CGImage から視覚塔の入力を作る。`positionTable` は `position_embeddings.f16` の中身。
    static func prepare(_ image: CGImage, budget: ImageTokenBudget, positionTable: Data) throws -> Prepared {
        let src = try srgbRGBX(image)
        let (th, tw) = targetSize(height: image.height, width: image.width, budget: budget)
        let px = resizeBicubic(rgbx: src, width: image.width, height: image.height, toWidth: tw, toHeight: th)
        return try patchify(rgbx: px, width: tw, height: th, budget: budget, positionTable: positionTable)
    }

    /// 縮小済みの RGBX（辺は 48 の倍数）をパッチに並べる。
    static func patchify(rgbx px: [UInt8], width tw: Int, height th: Int, budget: ImageTokenBudget,
                         positionTable: Data) throws -> Prepared {
        let P = patchSize, K = poolingKernel, D = patchValues
        let N = budget.maxPatches, T = budget.rawValue
        let ph = th / P, pw = tw / P, n = ph * pw
        guard th % (P * K) == 0, tw % (P * K) == 0, n <= N, pw <= positionTableRows, ph <= positionTableRows else {
            throw EmbeddingError.invalidImage("resized image \(tw)x\(th) does not fit \(N) patches")
        }
        guard positionTable.count >= 2 * positionTableRows * D * 2 else {
            throw EmbeddingError.invalidAsset("position_embeddings.f16 is too small")
        }
        let patches = try MLMultiArray(shape: [1, NSNumber(value: N), NSNumber(value: D)], dataType: .float16)
        let positions = try MLMultiArray(shape: [1, NSNumber(value: N), 2], dataType: .float16)
        let pool = try MLMultiArray(shape: [NSNumber(value: T), NSNumber(value: N)], dataType: .float16)
        let valid = try MLMultiArray(shape: [1, NSNumber(value: N)], dataType: .float16)
        let pe = try MLMultiArray(shape: [1, NSNumber(value: N), NSNumber(value: D)], dataType: .float16)
        let pp = patches.dataPointer.assumingMemoryBound(to: Float16.self)
        let pos = positions.dataPointer.assumingMemoryBound(to: Float16.self)
        let pl = pool.dataPointer.assumingMemoryBound(to: Float16.self)
        let vd = valid.dataPointer.assumingMemoryBound(to: Float16.self)
        let pep = pe.dataPointer.assumingMemoryBound(to: Float16.self)
        pp.update(repeating: 0, count: N * D)
        pl.update(repeating: 0, count: T * N)
        vd.update(repeating: 0, count: N)
        pep.update(repeating: 0, count: N * D)
        pos.update(repeating: -1, count: N * 2)
        // 0…255 / 255 の fp16 を先に作っておく
        let lut = (0..<256).map { Float16(Float($0) / 255) }
        let gw = pw / K
        let ninth = Float16(Float(1.0 / 9.0))
        px.withUnsafeBufferPointer { s in
            positionTable.withUnsafeBytes { raw in
                let tab = raw.bindMemory(to: Float16.self)
                for py in 0..<ph {
                    for pxi in 0..<pw {
                        let i = py * pw + pxi
                        let base = i * D
                        for r in 0..<P {
                            for c in 0..<P {
                                let sp = ((py * P + r) * tw + (pxi * P + c)) * 4
                                let dp = base + (r * P + c) * 3
                                pp[dp] = lut[Int(s[sp])]; pp[dp + 1] = lut[Int(s[sp + 1])]; pp[dp + 2] = lut[Int(s[sp + 2])]
                            }
                        }
                        pos[2 * i] = Float16(Float(pxi))
                        pos[2 * i + 1] = Float16(Float(py))
                        vd[i] = 1
                        pl[((py / K) * gw + pxi / K) * N + i] = ninth
                        let xRow = pxi * D, yRow = (positionTableRows + py) * D
                        for d in 0..<D { pep[base + d] = Float16(Float(tab[xRow + d]) + Float(tab[yRow + d])) }
                    }
                }
            }
        }
        return Prepared(patches: patches, positions: positions, pool: pool, valid: valid, positionEmbeddings: pe,
                        softTokens: n / (K * K), resizedWidth: tw, resizedHeight: th)
    }
}
