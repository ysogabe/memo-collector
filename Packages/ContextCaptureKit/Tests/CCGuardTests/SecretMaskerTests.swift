import CCCore
import CoreGraphics
import XCTest
@testable import CCGuard

final class SecretMaskerTests: XCTestCase {
    /// s13 の検出結果でマスクし、値の位置が黒く、他（ユーザー名・下の空白）は元のままであることを見る。
    /// 上下反転の誤りがあると、塗りが画面の下側（y≈0.75）に出て値が残る。
    func testMaskPaintsDetectedRegionOnlyAtTopLeftCoordinates() async throws {
        let image = try GuardFixtures.image("s13")
        let findings = try await VisionSecretScanner().scan(image: image)
        let pw = try XCTUnwrap(findings.first { $0.kind == "password_field" && abs($0.bbox.midY - 0.25) < 0.02 })
        let masked = try XCTUnwrap(SecretMasker.mask(image: image, findings: findings))
        XCTAssertEqual(masked.width, image.width)
        XCTAssertEqual(masked.height, image.height)

        let w = CGFloat(image.width), h = CGFloat(image.height)
        // 値の中心と、値の左端付近（文字の上）。
        for (fx, fy) in [(pw.bbox.midX, pw.bbox.midY), (pw.bbox.minX + 0.01, pw.bbox.midY)] {
            let p = GuardFixtures.pixel(masked, x: Int(fx * w), y: Int(fy * h))
            XCTAssertTrue(p.r < 10 && p.g < 10 && p.b < 10, "値の位置が塗られていない: \(p)")
        }
        // 上下反転した位置（y = 1 - midY）と、ユーザー名の行は元のまま。
        for (fx, fy) in [(pw.bbox.midX, 1 - pw.bbox.midY), (0.5, 0.165)] {
            let x = Int(fx * w), y = Int(fy * h)
            XCTAssertEqual(GuardFixtures.pixel(masked, x: x, y: y).r, GuardFixtures.pixel(image, x: x, y: y).r)
        }
    }

    func testPixelRectsAddPaddingAndClamp() {
        let f = SecretFinding(kind: "x", bbox: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.02))
        let r = SecretMasker.pixelRects(findings: [f], width: 1000, height: 1000)[0]
        // 高さ 20px、余白 max(4, 20*0.35=7) = 7。
        XCTAssertEqual(r.minX, 493, accuracy: 1)
        XCTAssertEqual(r.minY, 493, accuracy: 1)
        XCTAssertEqual(r.height, 34, accuracy: 1)
        let edge = SecretFinding(kind: "x", bbox: CGRect(x: 0.99, y: 0.0, width: 0.01, height: 0.01))
        let e = SecretMasker.pixelRects(findings: [edge], width: 100, height: 100)[0]
        XCTAssertLessThanOrEqual(e.maxX, 100)
        XCTAssertGreaterThanOrEqual(e.minY, 0)
    }

    func testNoFindingsReturnsUnchangedCopy() throws {
        let image = try GuardFixtures.image("s01")
        let out = try XCTUnwrap(SecretMasker.mask(image: image, findings: []))
        let a = GuardFixtures.pixel(image, x: 100, y: 100), b = GuardFixtures.pixel(out, x: 100, y: 100)
        XCTAssertEqual(a.r, b.r); XCTAssertEqual(a.g, b.g); XCTAssertEqual(a.b, b.b)
    }
}
