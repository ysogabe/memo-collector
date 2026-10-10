import CCCore
import CoreGraphics
import XCTest
@testable import CCGuard

/// 14 画面（`poc/fixtures/screens/`）での検出精度・位置・時間。PRD §8.1 の「4/4・誤検知 0」を保証する。
final class VisionSecretScannerTests: XCTestCase {
    let scanner = VisionSecretScanner()

    func testFourteenScreensDetectAllSecretsWithoutFalsePositives() async throws {
        // 初回は Vision のモデル読み込みが乗る（PoC では 17 秒の外れ値）。cold と warm を分けて記録する。
        let warmupStart = Date()
        _ = try await scanner.scan(image: try GuardFixtures.image("s01"))
        let coldMs = Int(Date().timeIntervalSince(warmupStart) * 1000)

        var table = ["| 画面 | 正解 | 検出 | kind | ms |", "|---|---|---|---|---|"]
        var times: [Int] = []
        for id in GuardFixtures.screenIDs {
            let image = try GuardFixtures.image(id)
            let t0 = Date()
            let findings = try await scanner.scan(image: image)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            times.append(ms)
            let gold = GuardFixtures.secretScreens.contains(id)
            let kinds = Array(Set(findings.map(\.kind))).sorted().joined(separator: ", ")
            table.append("| \(id) | \(gold ? "あり" : "なし") | \(findings.isEmpty ? "なし" : "あり(\(findings.count))") | \(kinds) | \(ms) |")
            if gold {
                XCTAssertFalse(findings.isEmpty, "\(id): 秘密を見逃した")
            } else {
                XCTAssertEqual(findings.map(\.kind), [], "\(id): 誤検知")
            }
            for f in findings {
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(f.bbox), "\(id): bbox が 0–1 の外")
            }
        }
        let sorted = times.sorted()
        print("CCGuard 14 画面（cold \(coldMs) ms、warm p50 \(sorted[sorted.count / 2]) ms、max \(sorted.last!) ms）")
        print(table.joined(separator: "\n"))
        // PoC の p50 0.154 秒。CI の揺れを見込んで warm の中央値 1 秒以内を上限にする。
        XCTAssertLessThan(sorted[sorted.count / 2], 1000)
    }

    /// s07（.env）: 4 行それぞれの秘密が別々に当たる（大文字に読まれた `SK-proj-` / `SK_Live_` も）。
    func testS07EachSecretLineIsFound() async throws {
        let findings = try await scanner.scan(image: try GuardFixtures.image("s07"))
        // 行の y（左上原点、OCR ダンプより）: DATABASE_URL 0.109、OPENAI 0.132、ANTHROPIC 0.158、STRIPE 0.183。
        assertFinding(findings, kind: "dsn_password", rowY: 0.118)
        assertFinding(findings, kind: "openai_key", rowY: 0.142)
        assertFinding(findings, kind: "anthropic_key", rowY: 0.167)
        assertFinding(findings, kind: "stripe_key", rowY: 0.192)
        // HERMES_ENDPOINT（http://127.0.0.1:8787）と NODE_ENV は秘密ではない。
        XCTAssertFalse(findings.contains { $0.bbox.midY > 0.205 }, "endpoint 行を誤検知")
        XCTAssertFalse(findings.contains { $0.bbox.midY < 0.1 }, "コメント・NODE_ENV 行を誤検知")
        // 値の範囲だけを覆う（キー名 `OPENAI_API_KEY=` の左端 0.228 より右から始まる）。
        let openai = try XCTUnwrap(findings.first { $0.kind == "openai_key" })
        XCTAssertGreaterThan(openai.bbox.minX, 0.28)
    }

    /// s08（AWS）: アクセスキーと、見出しのすぐ下にある secret access key の値。
    func testS08AccessKeyAndSecretValue() async throws {
        let findings = try await scanner.scan(image: try GuardFixtures.image("s08"))
        let access = assertFinding(findings, kind: "aws_access_key", rowY: 0.406)
        XCTAssertLessThan(access?.bbox.maxX ?? 1, 0.25)
        // 値（y≈0.391–0.419、x≈0.30–0.56）を覆う。見出し行（y≈0.37–0.394）ではなく値の行。
        let secret = assertFinding(findings, kind: "aws_secret_label", rowY: 0.405)
        XCTAssertGreaterThan(secret?.bbox.minX ?? 0, 0.28)
        XCTAssertGreaterThan(secret?.bbox.maxX ?? 0, 0.5)
        // 「the secret access key can be viewed…」の注意書き（y≈0.30）は文中の言及なので当てない。
        XCTAssertFalse(findings.contains { $0.bbox.midY < 0.34 }, "注意書きを秘密扱いした")
    }

    /// s11（gh の hosts.yml）: 2 行の oauth_token が両方当たり、`oauth_token:` のキー名は含まない。
    func testS11BothOauthTokenLines() async throws {
        let findings = try await scanner.scan(image: try GuardFixtures.image("s11"))
        let tokens = findings.filter { $0.kind == "github_token" }.sorted { $0.bbox.minY < $1.bbox.minY }
        XCTAssertEqual(tokens.count, 2)
        guard tokens.count == 2 else { return }
        XCTAssertEqual(tokens[0].bbox.midY, 0.243, accuracy: 0.02)
        XCTAssertEqual(tokens[1].bbox.midY, 0.290, accuracy: 0.02)
        // 1 行目は値だけの observation（x≈0.154–0.414）、2 行目は `oauth_token: ` の後ろから（x≈0.10 以降）。
        XCTAssertGreaterThan(tokens[0].bbox.minX, 0.14)
        XCTAssertGreaterThan(tokens[0].bbox.maxX, 0.38)
        XCTAssertGreaterThan(tokens[1].bbox.minX, 0.09)
        XCTAssertGreaterThan(tokens[1].bbox.maxX, 0.33)
        XCTAssertEqual(findings.count, 2, "トークン以外を当てた: \(findings.map(\.kind))")
    }

    /// s13（1Password）: 「パスワード（表示中）」の見出しではなく、その下の値を覆う。
    func testS13PasswordValueBelowLabel() async throws {
        let findings = try await scanner.scan(image: try GuardFixtures.image("s13"))
        let pw = findings.filter { $0.kind == "password_field" }
        // 値の行 y≈0.237–0.264。
        XCTAssertTrue(pw.contains { abs($0.bbox.midY - 0.25) < 0.02 }, "パスワードの値を覆っていない")
        // ユーザー名（y≈0.163）は秘密ではない。
        XCTAssertFalse(findings.contains { $0.bbox.midY < 0.2 })
    }

    func testCleanScreenCountMatchesPoC() async throws {
        var fp = 0
        for id in GuardFixtures.screenIDs where !GuardFixtures.secretScreens.contains(id) {
            if try await !scanner.scan(image: GuardFixtures.image(id)).isEmpty { fp += 1 }
        }
        XCTAssertEqual(fp, 0)
    }

    @discardableResult
    private func assertFinding(_ findings: [SecretFinding], kind: String, rowY: CGFloat,
                               file: StaticString = #filePath, line: UInt = #line) -> SecretFinding? {
        let hit = findings.first { $0.kind == kind && abs($0.bbox.midY - rowY) < 0.02 }
        XCTAssertNotNil(hit, "\(kind) が y≈\(rowY) に無い: \(findings.map { ($0.kind, $0.bbox.midY) })", file: file, line: line)
        return hit
    }
}
