import CoreGraphics
import XCTest
@testable import CCEmbedding

/// モデル（Core ML）を使わない単体テスト。トークナイザ・前処理は tokenizer.json と評価データがあれば走る。
final class EmbeddingUnitTests: XCTestCase {
    // MARK: - ベクトル

    func testTruncateAndNormalize() {
        let v: [Float] = [3, 4] + [Float](repeating: 100, count: 766)
        let r = EmbeddingVector.truncateAndNormalize(v, to: 2)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(r[1], 0.8, accuracy: 1e-6)
        let r256 = EmbeddingVector.truncateAndNormalize((0..<768).map { Float($0 % 7) - 3 }, to: 256)
        XCTAssertEqual(r256.count, 256)
        XCTAssertEqual(r256.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-5)
        XCTAssertEqual(EmbeddingVector.truncateAndNormalize([0, 0, 0], to: 2), [0, 0])
    }

    func testConfigurationClampsDimensionAndSignature() {
        let c = CoreMLEmbedder.Configuration(modelDirectory: URL(fileURLWithPath: "/tmp"), imageTokens: .tokens70, dimension: 4096)
        XCTAssertEqual(c.dimension, 768)
        XCTAssertEqual(c.textComputeUnits, .cpuAndNeuralEngine)
        XCTAssertEqual(c.visionComputeUnits, .cpuAndNeuralEngine)
        XCTAssertEqual(CoreMLEmbedder.Configuration(modelDirectory: URL(fileURLWithPath: "/tmp")).indexSignature,
                       "embeddinggemma-2-coreml@3f978dd/d256/img280")
        XCTAssertEqual(c.indexSignature, "embeddinggemma-2-coreml@3f978dd/d768/img70")
    }

    func testPrompts() {
        XCTAssertEqual(EmbeddingPrompt.query("会議"), "task: search result | query: 会議")
        XCTAssertEqual(EmbeddingPrompt.document(text: "a\nb", title: "T"), "title: T | text: a\nb")
        XCTAssertEqual(EmbeddingPrompt.document(text: "a", title: nil), "title: none | text: a")
        XCTAssertEqual(EmbeddingPrompt.document(text: "a", title: ""), "title: none | text: a")
        XCTAssertEqual(EmbeddingPrompt.fused(text: "a", title: "T"), "title: T | text: a <|image|>")
    }

    func testMissingModelFilesThrowWithoutLoading() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("no-model-\(UUID().uuidString)")
        let e = CoreMLEmbedder(configuration: .init(modelDirectory: dir))
        do {
            _ = try await e.embedQuery("x")
            XCTFail("should throw")
        } catch let EmbeddingError.modelFilesMissing(_, missing) {
            XCTAssertEqual(Set(missing), Set(EmbeddingModelFiles.textRequired))
        } catch { XCTFail("\(error)") }
        let loaded = await e.isLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(e.dimension, 256)
    }

    // MARK: - 前処理

    func testTargetSizeMatchesHFFormula() {
        // 1440×900 → 280: 2520 パッチ以内・辺は 48 の倍数（スパイクで HF と一致した値）
        let (h, w) = ImagePreprocessor.targetSize(height: 900, width: 1440, budget: .tokens280)
        XCTAssertEqual(h % 48, 0)
        XCTAssertEqual(w % 48, 0)
        XCTAssertLessThanOrEqual((h / 16) * (w / 16), 2520)
        // Retina（2880×1800）でも同じ大きさになる（比率だけで決まる）
        let r = ImagePreprocessor.targetSize(height: 1800, width: 2880, budget: .tokens280)
        XCTAssertEqual(r.height, h)
        XCTAssertEqual(r.width, w)
        for b in ImageTokenBudget.allCases {
            let s = ImagePreprocessor.targetSize(height: 900, width: 1440, budget: b)
            XCTAssertLessThanOrEqual((s.height / 16) * (s.width / 16), b.maxPatches)
        }
        // 極端に細長い
        let thin = ImagePreprocessor.targetSize(height: 10, width: 5000, budget: .tokens70)
        XCTAssertEqual(thin.height, 48)
        XCTAssertLessThanOrEqual(thin.width, 70 * 48)
    }

    /// 37×23 の決まった模様を 12×8 に縮小した値（PIL `Image.BICUBIC` と torchvision `resize(antialias=True)` が
    /// どちらもこの値を出す。生成: poc/.venv で同じ式の画像を作って比較）。
    func testBicubicMatchesPILAndTorchvision() {
        let W = 37, H = 23, TW = 12, TH = 8
        var src = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let i = (y * W + x) * 4
                src[i] = UInt8((x * 7 + y * 3) % 256)
                src[i + 1] = UInt8((x * x + 2 * y * 5) % 256)
                src[i + 2] = UInt8(((255 - x * 6 + y * y) % 256 + 256) % 256)
            }
        }
        let out = ImagePreprocessor.resizeBicubic(rgbx: src, width: W, height: H, toWidth: TW, toHeight: TH)
        var rgb: [Int] = []
        for p in 0..<(TW * TH) { rgb += [Int(out[p * 4]), Int(out[p * 4 + 1]), Int(out[p * 4 + 2])] }
        XCTAssertEqual(rgb, Self.bicubicExpected)
    }

    static let bicubicExpected = [11, 12, 200, 31, 27, 243, 53, 62, 213, 75, 117, 194, 97, 194, 176, 118, 80, 157, 140, 139, 139, 161, 125, 120, 183, 142, 102, 205, 115, 83, 229, 103, 64, 229, 124, 47, 19, 40, 59, 39, 55, 198, 61, 90, 240, 83, 148, 212, 105, 190, 190, 126, 76, 170, 148, 160, 152, 169, 95, 133, 191, 138, 115, 213, 119, 96, 241, 136, 77, 129, 148, 60, 28, 69, 29, 48, 84, 34, 70, 119, 118, 92, 184, 201, 114, 136, 226, 135, 73, 211, 157, 179, 188, 178, 106, 164, 200, 150, 146, 224, 119, 127, 230, 126, 108, 38, 106, 91, 37, 98, 84, 57, 113, 64, 79, 147, 36, 101, 209, 40, 123, 89, 87, 144, 109, 157, 166, 168, 194, 187, 103, 214, 209, 139, 204, 239, 138, 181, 170, 125, 158, 11, 127, 138, 45, 126, 151, 65, 141, 134, 87, 182, 111, 109, 193, 89, 131, 59, 65, 152, 147, 47, 174, 137, 44, 195, 126, 87, 218, 131, 131, 241, 135, 162, 68, 126, 194, 17, 122, 206, 54, 155, 193, 74, 170, 181, 96, 216, 195, 118, 115, 179, 140, 65, 164, 161, 176, 143, 183, 115, 119, 204, 143, 93, 231, 109, 67, 213, 140, 56, 23, 123, 62, 32, 113, 85, 63, 184, 76, 83, 204, 66, 105, 207, 96, 127, 50, 95, 149, 105, 147, 170, 178, 146, 192, 80, 186, 213, 166, 176, 243, 115, 184, 115, 139, 164, 12, 146, 143, 43, 141, 122, 71, 213, 175, 91, 225, 157, 113, 89, 133, 135, 52, 113, 157, 139, 92, 178, 176, 78, 200, 86, 79, 223, 153, 79, 235, 112, 114, 41, 123, 100, 26, 120, 163, 51, 141, 157]

    /// Display P3 で作った画像が sRGB の値に変換されて取り出されること（ScreenCaptureKit の P3 画像を想定）。
    func testDisplayP3ImageIsConvertedToSRGB() throws {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!, p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let colors: [[CGFloat]] = [[0.2, 0.6, 0.4], [0.9, 0.3, 0.1], [0.5, 0.5, 0.5]]
        // sRGB の色を P3 の成分に変換し、P3 タグ付きの 8bit 画像（1 色 4×4）にする
        for c in colors {
            let p3c = CGColor(colorSpace: srgb, components: c + [1])!.converted(to: p3, intent: .defaultIntent, options: nil)!
            let comps = p3c.components!.prefix(3).map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
            var px = [UInt8](repeating: 255, count: 4 * 4 * 4)
            for i in 0..<16 { px[i * 4] = comps[0]; px[i * 4 + 1] = comps[1]; px[i * 4 + 2] = comps[2] }
            let img = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: p3,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent)!
            let out = try ImagePreprocessor.srgbRGBX(img)
            for ch in 0..<3 {
                XCTAssertEqual(Double(out[ch]), Double(c[ch] * 255), accuracy: 2.5, "color \(c) ch \(ch)")
            }
            // P3 の成分をそのまま読んだ場合とは違う値になっている（変換が効いている）こと
            if c != [0.5, 0.5, 0.5] {
                XCTAssertNotEqual(Array(out[0..<3]), comps)
            }
        }
    }

    /// 評価用スクショ 14 枚で、パッチ値・位置・ソフトトークン数が HF の processor の出力（st_inputs.npz）と一致する。
    func testPreprocessMatchesHFPixelValues() throws {
        let npz = try NPZ(EmbeddingFixtures.require("spikes/fluid/data/st_inputs.npz"))
        let meta = try EmbeddingFixtures.referenceMeta()
        let positionTable = Data(count: 2 * 1024 * 768 * 2)  // 位置埋め込みはここでは見ない
        var maxDiff: Float = 0, over: Int = 0, total = 0
        for (i, sid) in meta.scr_ids.enumerated() {
            try autoreleasepool {
                let img = try EmbeddingFixtures.screen(sid)
                let p = try ImagePreprocessor.prepare(img, budget: .tokens280, positionTable: positionTable)
                let hf = try npz.array("img\(i)__pixel_values")
                let hfPos = try npz.array("img\(i)__image_position_ids").ints!
                let ids = try npz.array("img\(i)__input_ids").ints!
                XCTAssertEqual(p.softTokens, ids.filter { $0 == 258_880 }.count, "soft tokens \(sid)")
                let n = p.softTokens * 9
                let pp = p.patches.dataPointer.assumingMemoryBound(to: Float16.self)
                let hv = hf.floats!
                for j in 0..<(n * 768) {
                    let d = abs(Float(pp[j]) - hv[j])
                    maxDiff = max(maxDiff, d)
                    if d > 0.6 / 255 { over += 1 }
                }
                total += n * 768
                let pos = p.positions.dataPointer.assumingMemoryBound(to: Float16.self)
                for j in 0..<(n * 2) { XCTAssertEqual(Int64(Float(pos[j])), hfPos[j], "position \(sid) \(j)") ; if Int64(Float(pos[j])) != hfPos[j] { break } }
            }
        }
        metric("preprocess vs HF: max |diff| = \(maxDiff * 255)/255, values off by >0.6/255: \(over)/\(total)")
        // 縮小は torchvision の uint8 経路とビット一致するので、差は fp16 への丸め（< 0.25/255）だけ
        XCTAssertLessThan(maxDiff, 0.25 / 255)
        XCTAssertEqual(over, 0)
    }

    // MARK: - トークナイザ（tokenizer.json が要る）

    private func builder() throws -> EmbeddingSequenceBuilder {
        guard let url = try EmbeddingFixtures.tokenizerURL() else { throw XCTSkip("tokenizer.json not found") }
        return EmbeddingSequenceBuilder(tokenizer: try EmbeddingGemma2Tokenizer(tokenizerJsonURL: url))
    }

    /// HF tokenizers の id 列と 50/50 一致（文書 30 件は注釈 + "\n" 区切りのメタを含む）。
    func testTokenizerMatchesHF() throws {
        let b = try builder()
        struct Item: Decodable { let kind: String; let text: String; let ids: [Int32] }
        struct File: Decodable { let items: [Item] }
        let items = try JSONDecoder().decode(File.self, from: Data(contentsOf:
            EmbeddingFixtures.require("spikes/runtime/data/embed_text_ids.json"))).items
        XCTAssertEqual(items.count, 50)
        XCTAssertGreaterThanOrEqual(items.filter { $0.text.contains("\n") }.count, 30)
        var same = 0
        for it in items {
            let ids = b.text(it.text)
            if ids == it.ids { same += 1 } else { XCTFail("mismatch \(it.kind): \(it.text.prefix(40))") }
        }
        metric("tokenizer vs HF: \(same)/\(items.count)")
    }

    /// 改行（単独 LF・連続 LF・CRLF）を含む文字列でも、LF が 1 トークンとして残り、往復で失われないこと。
    func testTokenizerKeepsNewlines() throws {
        let b = try builder()
        let lf = b.tokenizer.tokenize("\n")
        XCTAssertEqual(lf.count, 1, "single LF should be one token")
        let ids = b.tokenizer.tokenize("あ\nい")
        XCTAssertTrue(ids.contains(lf[0]), "LF between CJK should stay a LF token")
        let two = b.tokenizer.tokenize("a\n\nb")
        XCTAssertFalse(two.isEmpty)
        XCTAssertNotEqual(b.tokenizer.tokenize("a\nb"), b.tokenizer.tokenize("a b"))
        XCTAssertNotEqual(b.tokenizer.tokenize("a\r\nb"), b.tokenizer.tokenize("a\nb"))
    }

    /// 融合列が HF の processor の input_ids と 30/30 一致。
    func testFusedSequenceMatchesHF() throws {
        let b = try builder()
        let npz = try NPZ(EmbeddingFixtures.require("spikes/fluid/data/st_inputs.npz"))
        let meta = try EmbeddingFixtures.referenceMeta()
        var same = 0
        for (i, (text, sid)) in zip(meta.fused_texts, meta.cap_screens).enumerated() {
            let img = try EmbeddingFixtures.screen(sid)
            let n = try ImagePreprocessor.softTokens(for: img, budget: .tokens280)
            let hf = try npz.array("fu\(i)__input_ids").ints!.map { Int32($0) }
            let ids = b.fused(text, softTokens: n)
            if ids == hf { same += 1 } else { XCTFail("fused \(i) mismatch (\(ids.count) vs \(hf.count))") }
            // 画像のみの列も HF と一致
            if i < meta.scr_ids.count {
                let img2 = try EmbeddingFixtures.screen(meta.scr_ids[i])
                let n2 = try ImagePreprocessor.softTokens(for: img2, budget: .tokens280)
                XCTAssertEqual(b.image(softTokens: n2), try npz.array("img\(i)__input_ids").ints!.map { Int32($0) })
            }
        }
        metric("fused ids vs HF: \(same)/\(meta.fused_texts.count)")
    }

    /// 長い注釈でも 512 に収まり、画像トークン列は欠けずにテキストの末尾が切られる。
    func testFusedTruncationKeepsImageTokens() throws {
        let b = try builder()
        let long = String(repeating: "とても長い注釈です。", count: 400)
        let ids = b.fused(EmbeddingPrompt.fused(text: long, title: "T"), softTokens: 280)
        XCTAssertEqual(ids.count, 512)
        XCTAssertEqual(ids.filter { $0 == EmbeddingGemma2Tokens.softImage }.count, 280)
        XCTAssertEqual(ids.last, b.tokenizer.eosId)
        XCTAssertEqual(ids[ids.count - 2], EmbeddingGemma2Tokens.endImage)
        XCTAssertEqual(ids.first, b.tokenizer.bosId)
        XCTAssertLessThanOrEqual(b.text(long).count, 512)
    }
}
