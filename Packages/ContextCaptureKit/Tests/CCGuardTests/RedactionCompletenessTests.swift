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
