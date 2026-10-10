import AppKit
import CCCore
import CoreGraphics
import CoreText
import XCTest
@testable import CCGuard

/// マスク漏れ（incomplete redaction）の回帰テスト。
/// 1) PEM の秘密鍵は見出しだけでなく本体の base64 行まで覆う。
/// 2) 同じ行で重なる一致は和集合に広げる（狭い方だけを bbox にしない）。値は次の空白まで覆う。
final class RedactionCompletenessTests: XCTestCase {
    let detector = SecretDetector()

    private func line(_ text: String, y: CGFloat, x: CGFloat = 0.1, w: CGFloat = 0.5, h: CGFloat = 0.02,
                      charBoxes: Bool = false) -> OCRLine {
        let bbox = CGRect(x: x, y: y, width: w, height: h)
        guard charBoxes else { return OCRLine(text: text, bbox: bbox) }
        // 文字範囲の bbox を等幅で近似する（Vision の boundingBox(for:) の代わり）。
        let n = CGFloat(text.count)
        return OCRLine(text: text, bbox: bbox, boxForRange: { r in
            let a = CGFloat(text.distance(from: text.startIndex, to: r.lowerBound))
            let b = CGFloat(text.distance(from: text.startIndex, to: r.upperBound))
            return CGRect(x: x + w * a / n, y: y, width: w * (b - a) / n, height: h)
        })
    }

    // MARK: - 1) PEM ブロック

    private let pemBody = [
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW",
        "QyNTUxOQAAACBGQUtFRkFLRUZBS0VGQUtFRkFLRUZBS0VGQUtFRkFLRUZBAAAAoFAKEFAK",
        "RUZBS0VGQUtFRkFLRUZBS0VGQUtFRkFLRUZBS0VGQUtFRkFLRUZBS0VGQUtFRkFLRUZBS0",
    ]

    func testPrivateKeyBlockCoversBodyUntilEndLine() {
        var lines = [line("-----BEGIN OPENSSH PRIVATE KEY-----", y: 0.10, w: 0.3)]
        for (k, body) in pemBody.enumerated() { lines.append(line(body, y: 0.125 + CGFloat(k) * 0.025, w: 0.6)) }
        lines.append(line("-----END OPENSSH PRIVATE KEY-----", y: 0.20, w: 0.3))
        lines.append(line("$ ssh-keygen -l -f id_ed25519", y: 0.30, w: 0.3))
        let found = detector.detect(lines: lines).filter { $0.kind == "private_key" }
        XCTAssertEqual(found.count, 1)
        let box = try! XCTUnwrap(found.first).bbox
        XCTAssertLessThanOrEqual(box.minY, 0.10 + 1e-6)
        XCTAssertGreaterThanOrEqual(box.maxY, 0.22 - 1e-6, "END 行まで覆っていない")
        XCTAssertGreaterThanOrEqual(box.maxX, 0.7 - 1e-6, "本体（見出しより幅が広い）を覆っていない")
        XCTAssertLessThan(box.maxY, 0.30, "END より下の無関係な行まで覆った")
    }

    func testPrivateKeyBlockWithoutEndCoversContiguousBase64Lines() {
        var lines = [line("-----BEGIN RSA PRIVATE KEY-----", y: 0.10, w: 0.3)]
        for (k, body) in pemBody.enumerated() { lines.append(line(body, y: 0.125 + CGFloat(k) * 0.025, w: 0.6)) }
        // 塊の後に空き行を挟んだ別の文（base64 ではない）。END は画面外。
        lines.append(line("Press any key to continue", y: 0.25, w: 0.3))
        let box = try! XCTUnwrap(detector.detect(lines: lines).first { $0.kind == "private_key" }).bbox
        XCTAssertGreaterThanOrEqual(box.maxY, 0.125 + 2 * 0.025 + 0.02 - 1e-6, "本体の最終行まで覆っていない")
        XCTAssertLessThan(box.maxY, 0.25)
    }

    /// PEM を描いた模擬画面を実際に OCR にかけ、マスク後に本体行の位置が塗られていることを確かめる。
    func testRenderedPEMBodyIsMaskedAfterOCR() async throws {
        let text = ["-----BEGIN OPENSSH PRIVATE KEY-----"] + pemBody + ["-----END OPENSSH PRIVATE KEY-----", "", "done."]
        let (image, lineCenters) = Self.renderMonospace(lines: text, width: 1440, height: 900)
        let findings = try await VisionSecretScanner().scan(image: image)
        XCTAssertTrue(findings.contains { $0.kind == "private_key" }, "PEM を検出しない: \(findings.map(\.kind))")
        let masked = try XCTUnwrap(SecretMasker.mask(image: image, findings: findings))
        // 本体 3 行の中央付近（文字のある x）と END 行が黒い。
        for row in 1...4 {
            let p = GuardFixtures.pixel(masked, x: 300, y: Int(lineCenters[row]))
            XCTAssertTrue(p.r < 10 && p.g < 10 && p.b < 10, "行 \(row) が塗られていない: \(p)")
        }
        // 「done.」の行（ブロックの外）は元のまま（背景が白）。
        let outside = GuardFixtures.pixel(masked, x: 600, y: Int(lineCenters[6]))
        XCTAssertGreaterThan(outside.r, 200)
    }

    /// END が見えず、本体に OCR の誤読（base64 外の文字が少し・1 行まるごと崩れた行）と短い最終行があっても、
    /// 本体の最後まで覆い、大きな空きの後の行は覆わない。
    func testPrivateKeyFallbackToleratesOCRNoiseAndShortLastLine() {
        let body = [
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW",
            "QyNTUxOQAAACBGQUtFRk-FLRUZBS0VGQU.tFRkFLRUZBS0VGQUtFRkFLRUZBAAAAoFAKEFAK", // 誤読 2 文字（3%）
            "~~ ##: |-- ;;",                                                                 // 1 行まるごと崩れた
            "RUZBS0VGQUtFRkFLRUZBS0VGQUtFRkFLRUZBS0VGQUtFRkFLRUZBS0VGQUtFRkFLRUZBS0",
            "AAAA==",                                                                        // 短い最終行
        ]
        var lines = [line("-----BEGIN OPENSSH PRIVATE KEY-----", y: 0.10, w: 0.3)]
        for (k, b) in body.enumerated() { lines.append(line(b, y: 0.125 + CGFloat(k) * 0.025, w: k == 4 ? 0.06 : 0.6)) }
        // 大きな空き（3 行分）の後のプロンプト行は鍵ではない。
        lines.append(line("AAAABBBBCCCCDDDD", y: 0.125 + 4 * 0.025 + 0.08, w: 0.2))
        let box = try! XCTUnwrap(detector.detect(lines: lines).first { $0.kind == "private_key" }).bbox
        XCTAssertGreaterThanOrEqual(box.maxY, 0.125 + 4 * 0.025 + 0.02 - 1e-6, "短い最終行まで覆っていない")
        XCTAssertLessThan(box.maxY, 0.125 + 4 * 0.025 + 0.08, "大きな空きの後の行まで覆った")
    }

    func testPrivateKeyFallbackStopsAfterTwoConsecutiveNonBodyLines() {
        var lines = [line("-----BEGIN RSA PRIVATE KEY-----", y: 0.10, w: 0.3)]
        lines.append(line(pemBody[0], y: 0.125, w: 0.6))
        lines.append(line("$ echo done", y: 0.15, w: 0.2))
        lines.append(line("[exit 0] ok.", y: 0.175, w: 0.1))  // 短い英単語だけの行は base64 と区別できない（塗り過ぎは許容）ので記号入りにする
        lines.append(line(pemBody[1], y: 0.20, w: 0.6))
        let box = try! XCTUnwrap(detector.detect(lines: lines).first { $0.kind == "private_key" }).bbox
        XCTAssertEqual(box.maxY, 0.145, accuracy: 1e-6)
    }

    func testBase64BodyHeuristic() {
        XCTAssertTrue(SecretDetector.looksLikeBase64Body("AAAA=="))
        XCTAssertTrue(SecretDetector.looksLikeBase64Body("QyNTUxOQAAACBGQUtFRk-FLRUZBS0VGQU.tFRkFLRUZB"))
        XCTAssertFalse(SecretDetector.looksLikeBase64Body("$ echo done"))
        XCTAssertFalse(SecretDetector.looksLikeBase64Body(""))
    }

    /// END の無い PEM（画面の途中で切れた表示）を描いて OCR → マスクし、短い最終行まで塗られることを確かめる。
    func testRenderedPEMWithoutEndMasksShortLastLine() async throws {
        let text = ["-----BEGIN OPENSSH PRIVATE KEY-----"] + pemBody + ["AAAAC3Nz==", "", "", "", "done."]
        let (image, centers) = Self.renderMonospace(lines: text, width: 1440, height: 900)
        let findings = try await VisionSecretScanner().scan(image: image)
        let masked = try XCTUnwrap(SecretMasker.mask(image: image, findings: findings))
        for row in 1...4 {
            let p = GuardFixtures.pixel(masked, x: 60, y: Int(centers[row]))
            XCTAssertTrue(p.r < 10 && p.g < 10 && p.b < 10, "行 \(row) が塗られていない: \(p)")
        }
        XCTAssertGreaterThan(GuardFixtures.pixel(masked, x: 60, y: Int(centers[8])).r, 200, "空きの後の行まで塗った")
    }

    // MARK: - 1 行の余白

    /// 1 行の検出には余白の上限をかけない（大きな文字でも上下端・ディセンダが塗られる）。
    func testSingleLinePaddingIsNotCappedByBlockLimit() {
        let tall = SecretFinding(kind: "openai_key", bbox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.06))
        let r = SecretMasker.pixelRects(findings: [tall], width: 1000, height: 1000)[0]
        XCTAssertEqual(r.height, 60 + 2 * 21, accuracy: 1, "1 行は bbox の高さ基準の余白（0.35 × 60px = 21px）")
        let block = SecretFinding(kind: "private_key", bbox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.3))
        let b = SecretMasker.pixelRects(findings: [block], width: 1000, height: 1000)[0]
        XCTAssertEqual(b.height, 300 + 2 * 14, accuracy: 1, "ブロックは 1 行分（0.04 × 1000 × 0.35 = 14px）で頭打ち")
    }

    /// 大きな文字で描いたキー 1 行を OCR → マスクし、元画像のインク（暗い画素）が 1 つも残らないことを確かめる。
    func testSingleLineMaskCoversAllInkIncludingDescenders() async throws {
        let ctx = CGContext(data: nil, width: 1440, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1440, height: 300))
        let font = CTFontCreateWithName("Menlo" as CFString, 34, nil)
        let attr = NSAttributedString(string: "sk-proj-FAKEgjpqyQjgpyJ0kLmNoPqRsTuvgjpq", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 40, y: 140)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        let image = ctx.makeImage()!
        let findings = try await VisionSecretScanner().scan(image: image)
        XCTAssertEqual(findings.map(\.kind), ["openai_key"])
        let masked = try XCTUnwrap(SecretMasker.mask(image: image, findings: findings))
        let before = GuardFixtures.rgba(image), after = GuardFixtures.rgba(masked)
        var inkLeft = 0, ink = 0
        for i in stride(from: 0, to: before.count, by: 4) where before[i] < 128 {
            ink += 1
            if !(after[i] < 10 && after[i + 1] < 10 && after[i + 2] < 10) { inkLeft += 1 }
        }
        XCTAssertGreaterThan(ink, 100)
        XCTAssertEqual(inkLeft, 0, "塗り残したインク画素がある")
    }

    /// 白地に Menlo で行を描く。各行の中心 y（ピクセル、左上原点）を返す。
    static func renderMonospace(lines: [String], width: Int, height: Int) -> (CGImage, [CGFloat]) {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 18, nil)
        let lineHeight: CGFloat = 26
        var centers: [CGFloat] = []
        for (i, s) in lines.enumerated() {
            let topY = 60 + CGFloat(i) * lineHeight
            centers.append(topY + lineHeight / 2)
            let attr = NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            let ctLine = CTLineCreateWithAttributedString(attr)
            // CGContext は左下原点。ベースラインを行の下寄りに置く。
            ctx.textPosition = CGPoint(x: 40, y: CGFloat(height) - topY - lineHeight * 0.75)
            CTLineDraw(ctLine, ctx)
        }
        return (ctx.makeImage()!, centers)
    }

    // MARK: - 2) 重なりの和集合・値の境界

    func testOverlappingMatchesAreUnionedNotDropped() {
        // stripe_key（先に評価）は `sk_live_…` から、secret_assignment は同じ値の位置から当たる。
        // ここでは狭い一致（stripe）の後ろに広い一致（secret_assignment が `!` 以降まで伸ばす）が重なる形にする。
        let text = "STRIPE_SECRET_KEY=sk_live_FAKE51Hc2kLmN0pQrStUv!x9-tail"
        let found = detector.detect(lines: [line(text, y: 0.1, charBoxes: true)])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, "stripe_key")
        // 値の先頭（"sk_live" の位置 = 18 文字目）から行末までを覆う。
        let n = CGFloat(text.count)
        let box = try! XCTUnwrap(found.first).bbox
        XCTAssertEqual(box.minX, 0.1 + 0.5 * 18 / n, accuracy: 1e-6)
        XCTAssertEqual(box.maxX, 0.6, accuracy: 1e-6)
    }

    func testMergeOverlappingKeepsEarliestKindAndUnion() {
        let merged = SecretDetector.mergeOverlapping([
            (NSRange(location: 10, length: 5), 3, "late"),
            (NSRange(location: 5, length: 8), 1, "early"),
            (NSRange(location: 30, length: 4), 2, "separate"),
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].range, NSRange(location: 5, length: 10))
        XCTAssertEqual(merged[0].kind, "early")
        XCTAssertEqual(merged[1].range, NSRange(location: 30, length: 4))
    }

    func testValueRangeExtendsToNextWhitespace() {
        // 値の途中に制限文字クラス外の文字（! や #）があっても、空白までを秘密範囲にする。
        let cases: [(String, String, String)] = [
            ("API_SECRET=ab12cd34ef56gh78!ij90#kl end", "secret_assignment", "ab12cd34ef56gh78!ij90#kl"),
            ("OPENAI_API_KEY=sk-proj-FAKEa1B2c3D4e5F6g7H8!i9J0 next", "openai_key", "sk-proj-FAKEa1B2c3D4e5F6g7H8!i9J0"),
            ("token ghp_FAKE0123456789abcdefghijABCDEFGHIJ$$ zz", "github_token", "ghp_FAKE0123456789abcdefghijABCDEFGHIJ$$"),
        ]
        for (text, kind, secret) in cases {
            let found = detector.detect(lines: [line(text, y: 0.1, charBoxes: true)])
            XCTAssertEqual(found.map(\.kind), [kind], text)
            let n = CGFloat(text.count)
            let start = CGFloat(text.distance(from: text.startIndex, to: text.range(of: secret)!.lowerBound))
            let box = try! XCTUnwrap(found.first).bbox
            XCTAssertEqual(box.minX, 0.1 + 0.5 * start / n, accuracy: 1e-6, text)
            XCTAssertEqual(box.width, 0.5 * CGFloat(secret.count) / n, accuracy: 1e-6, text)
        }
    }

    func testCodeAssignmentStillNotDetected() {
        for t in ["const accessToken = getToken(cfg.k1);", "let token: String = makeToken()"] {
            XCTAssertEqual(detector.detect(lines: [line(t, y: 0.1)]), [], t)
        }
    }
}
